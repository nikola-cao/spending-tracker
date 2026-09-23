//
//  AmexAlertParserTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

/// Fixtures taken verbatim from the user's real inbox, flattened to text the way `HTMLText`
/// would. Merchant names and amounts are the real ones — they are what the parser has to
/// survive, and invented ones would only test the parts that already work.
struct AmexAlertParserTests {

    // MARK: - The three real purchase alerts

    /// A real alert, exactly as `HTMLText` renders it.
    private static func purchaseAlert(
        account: String,
        merchant: String,
        amount: String,
        date: String
    ) -> String {
        """
        See the details about this purchase
        NIKOLA CAO
        Account Ending: \(account)
        There was a large purchase on your Card
        Dear NIKOLA CAO,
        As you requested, we're letting you know that this purchase was more than $1.00.
        You can change the dollar amount of these large purchase notifications online.
        \(merchant)
        $\(amount)*
        \(date)
        *The amount above may not reflect the final amount as some merchants issue a pre-authorization charge
        You can track this spending charge online and be notified when the final amount is posted to your account.
        If you still have questions about this transaction, we suggest contacting the merchant directly.
        Contact us
        Update your email address
        Privacy statement
        To stop alerts click here
        © 2026 American Express. All rights reserved.
        SAM0FYI568
        """
    }

    @Test func theAirbnbAlertParses() {
        let alert = AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21008", merchant: "AIRBNB US SHORT TERM STAY",
            amount: "515.66", date: "Tue, Sep 22, 2026"))

        #expect(alert?.amountMinor == 51566)
        #expect(alert?.merchant == "AIRBNB US SHORT TERM STAY")
        #expect(alert?.cardSuffix == "21008")
        #expect(alert?.currencyCode == "USD")
        #expect(alert?.isCharge == true)
        #expect(alert?.occurredAt != nil)
    }

    /// The second card. Amex prints FIVE digits, and the two cards differ in the fifth — so
    /// truncating to four would be fine today and wrong the moment two cards share a last four.
    @Test func theSecondCardIsDistinguished() {
        let alert = AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21006", merchant: "PUBLIX",
            amount: "14.20", date: "Tue, Sep 22, 2026"))

        #expect(alert?.cardSuffix == "21006")
        #expect(alert?.amountMinor == 1420)
        #expect(alert?.merchant == "PUBLIX")
    }

    @Test func aThirdRealAlertParses() {
        let alert = AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21006", merchant: "CINEMAPLUS",
            amount: "23.85", date: "Tue, Sep 22, 2026"))

        #expect(alert?.amountMinor == 2385)
        #expect(alert?.merchant == "CINEMAPLUS")
    }

    @Test func theDateComesFromTheMessage() throws {
        let alert = try #require(AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21008", merchant: "AIRBNB US SHORT TERM STAY",
            amount: "515.66", date: "Tue, Sep 22, 2026")))

        let date = try #require(alert.occurredAt)

        // No time in the message, so noon is used — a timezone shift then cannot drag the row
        // onto the previous day.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        #expect(calendar.component(.year, from: date) == 2026)
        #expect(calendar.component(.month, from: date) == 9)
        #expect(calendar.component(.day, from: date) == 22)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, yyyy"
        #expect(formatter.string(from: date) == "Tue, Sep 22, 2026")
    }

    // MARK: - The double-count guard
    //
    // This is the reason the parser is envelope-anchored rather than "find an amount".
    // The user's Email automation also captures the MERCHANT's confirmation for the very
    // same purchases, carrying the very same amounts. If those parsed, every online purchase
    // would be recorded twice — silently, and in the direction that inflates a total.

    /// A real Airbnb booking confirmation. Same $515.66 as the Amex alert above.
    private static let airbnbReceipt = """
        You're all set for Gatlinburg
        Charm of Gatlinburg Mountain Retreat condo
        Entire home/apt hosted by Rachel
        Check-in
        Sat, Oct 3
        After 3:00 PM
        Checkout
        Tue, Oct 6
        By 10:00 AM
        Address
        1260 Ski View Dr, Gatlinburg, TN 37738, USA
        Guests
        4 adults
        Price breakdown
        $172.00 x 3 nights
        $516.00
        Discount
        -$58.65
        Taxes
        $58.31
        Total (USD)
        $515.66
        Payment
        Amex 1008
        September 22, 2026, 8:39:03 PM EDT
        $515.66
        Get your receipt
        """

    /// A real CinemaPlus ticket confirmation. Same $23.85 as the Amex alert above.
    private static let cinemaPlusReceipt = """
        Thank you for your reservation!
        IPIC Atlanta
        Resident Evil
        Premium Plus Ticket x 1
        Sub total: $19.50
        Booking Fees: $2.40
        Tax: $1.95
        Total: $23.85
        Paid: $23.85 with Amex ******1006
        Receipt # : 9101
        Confirmation Code: WW68WCC
        """

    @Test func theMerchantReceiptsAreRejected() {
        // Each contains the exact amount and a date — everything a naive "find the money"
        // parser would need. Neither is an Amex alert.
        #expect(AmexAlertParser.parseAll(Self.airbnbReceipt).isEmpty)
        #expect(AmexAlertParser.parseAll(Self.cinemaPlusReceipt).isEmpty)
        #expect(AlertParsers.parseAll(Self.airbnbReceipt).isEmpty)
        #expect(AlertParsers.parseAll(Self.cinemaPlusReceipt).isEmpty)
    }

    /// A real Amex statement notice, which the filter also lets through.
    private static let statementNotice = """
        Log in to view your statement and see these changes online
        NIKOLA CAO
        Account ending: 21006
        Your September 2026 statement is ready
        Please view your PDF Billing Statement for an important notice(s) about your account.
        Payment due date:
        Friday, October 16, 2026
        View Your Statement
        Make a Payment
        © 2026 American Express. All rights reserved.
        SAM0FYI009
        """

    @Test func theStatementNoticeIsRejected() {
        // Note it carries "Account ending" and an Amex footer — matching on those alone would
        // wrongly accept it. The envelope sentence is what actually discriminates.
        #expect(AmexAlertParser.parseAll(Self.statementNotice).isEmpty)
    }

    // MARK: - HTML
    //
    // Amex alerts arrive as a full HTML document. This fixture mirrors the real markup: block
    // elements that must become line breaks, entities, and the invisible padding characters
    // Amex's templates use.

    private static let htmlAlert = """
        <!doctype html><html><head><style>.body-1{font-size:15px}</style></head><body>
        <table><tbody><tr><td><p class="body-1"><b>NIKOLA CAO</b></p><p class="body-1">Account Ending: 21008</p></td>
        <td align="right"><img src="https://www.aexp-static.com/card.jpg" alt="Card Art"></td></tr></tbody></table>
        <div><p>There was a large purchase on your Card</p></div>
        <p>Dear NIKOLA CAO,</p>
        <p>As you requested, we&rsquo;re letting you know that this purchase was more than $1.00.</p>
        <p>You can change the dollar amount of these large purchase notifications online.</p>
        <div style="font-weight:bold"><p style="margin:0 0 0 0px">AIRBNB US SHORT TERM STAY</p></div>
        <div><p style="margin:0 0 0 0px">$515.66*</p></div>
        <div><p style="margin:0 0 0 0px">Tue, Sep 22, 2026</p></div>
        <p>*The amount above may not reflect the final amount&nbsp;as some merchants issue a pre-authorization charge</p>
        <p>&#169; 2026 American Express. All rights reserved.</p>
        </body></html>
        """

    @Test func anHTMLBodyParsesEndToEnd() {
        let alert = AlertParsers.parseFirst(Self.htmlAlert)

        #expect(alert?.amountMinor == 51566)
        #expect(alert?.merchant == "AIRBNB US SHORT TERM STAY")
        #expect(alert?.cardSuffix == "21008")
        #expect(alert?.occurredAt != nil)
    }

    @Test func htmlExtractionKeepsAdjacentElementsApart() {
        // Without block-level breaks these fuse into "NIKOLA CAOAccount Ending: 21008" and
        // every anchor is lost.
        let text = HTMLText.extract(from: "<p>NIKOLA CAO</p><p>Account Ending: 21008</p>")
        #expect(text.contains("NIKOLA CAO\nAccount Ending: 21008"))
    }

    @Test func htmlExtractionStripsInvisiblePadding() {
        let padded = "<p>Account Ending: 21008\u{034F}\u{034F}\u{200B}</p>"
        #expect(HTMLText.extract(from: padded).contains("Account Ending: 21008"))
    }

    @Test func htmlExtractionLeavesPlainTextAlone() {
        let sms = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV."
        #expect(HTMLText.extract(from: sms) == sms)
    }

    /// The entities these templates actually emit, counted across the six real emails:
    /// `&shy;` 100, `&amp;` 88, `&quot;` 136, `&#847;` 150, `&#8199;` 150, `&#x27;` 7.
    @Test func theEntitiesTheRealEmailsUseAreDecoded() {
        let text = HTMLText.extract(from: "<p>a&shy;b&amp;c&quot;d&#847;e&#8199;f&#x27;g</p>")

        // &shy; -> U+00AD and &#847; -> U+034F are invisibles, removed outright — note they
        // leave NO space behind, so "d" and "e" end up adjacent. `&#847;` is a combining
        // joiner used as padding, and joining is what it does.
        // &#8199; -> U+2007 is a real space separator, and collapses to one.
        // &amp; and &quot; and &#x27; decode to their characters.
        #expect(text == "ab&c\"de f'g")
    }

    /// Decoded output must never be re-examined. `&amp;shy;` means the literal text `&shy;`,
    /// not a soft hyphen — a chain of `replacingOccurrences` passes would decode it twice, and
    /// in dictionary order, so whether it happened would vary between runs.
    @Test func entityDecodingIsSinglePass() {
        #expect(HTMLText.extract(from: "<p>&amp;shy;</p>") == "&shy;")
    }

    /// Better to leave an unrecognised entity visible than to silently turn it into something
    /// else, or to drop it and make a line look clean when it is not.
    @Test func anUnknownEntityIsLeftAlone() {
        #expect(HTMLText.extract(from: "<p>&weird; &#xZZ;</p>") == "&weird; &#xZZ;")
    }

    // MARK: - Cross-source safety

    /// The Fidelity parser must not claim an Amex body, and vice versa. If both could match,
    /// one purchase could produce two ledger rows.
    @Test func theTwoSourcesDoNotOverlap() {
        let amex = Self.htmlAlert
        let fidelity = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV."

        #expect(FidelityAlertParser.parseAll(HTMLText.extract(from: amex)).isEmpty)
        #expect(AmexAlertParser.parseAll(fidelity).isEmpty)
    }

    // MARK: - Amount shapes

    @Test func amountsUseTheSharedConverter() {
        let alert = AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21008", merchant: "SOME MERCHANT",
            amount: "1,204.99", date: "Tue, Sep 22, 2026"))
        #expect(alert?.amountMinor == 120499)
    }

    @Test func aMalformedAmountIsRejectedRatherThanGuessed() {
        // The same comma rule as the Fidelity path: "2,50" is ambiguous, so it is refused
        // instead of being read as $250.00.
        let alert = AmexAlertParser.parseFirst(Self.purchaseAlert(
            account: "21008", merchant: "SOME MERCHANT",
            amount: "2,50", date: "Tue, Sep 22, 2026"))
        #expect(alert == nil)
    }

    // MARK: - Merchant sanity

    @Test func aBoilerplateLineIsNotAMerchant() {
        // If the template shifts and the line above the amount becomes prose, the row must be
        // refused rather than recorded with boilerplate as its merchant.
        let broken = """
            Account Ending: 21008
            There was a large purchase on your Card
            As you requested, we're letting you know that this purchase was more than $1.00.
            $515.66*
            Tue, Sep 22, 2026
            """
        #expect(AmexAlertParser.parseAll(broken).isEmpty)
    }
}
