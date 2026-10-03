//
//  VenmoAlertParserTests.swift
//  spending-trackerTests
//
//  The five real emails the parser was written against, as `HTMLText` renders them. The bodies
//  are verbatim: the hidden preheader is in there, because it is in there in reality and it is
//  the whole reason this parser looks the way it does.
//

import Foundation
import Testing
@testable import spending_tracker

struct VenmoAlertParserTests {

    // MARK: - The corpus

    /// Money in, with a note. Carries the hidden `You paid Sarvesh Gade $28.00` preheader.
    static let receivedWithNote = """
        ---------- Forwarded message ---------
        From: Venmo < venmo@venmo.com >
        Date: Fri, Oct 2, 2026 at 9:01 PM
        Subject: Sarvesh Gade paid $28.00 to your Venmo account. Leave it in Venmo or transfer it to your bank account.
        To: < cao.nikola.a@gmail.com >
        You paid Sarvesh Gade $28.00
        Sarvesh Gade paid you
        $
        28
        .
        00
        Kimchi red
        See transaction
        Money credited to your Venmo account.
        Transaction details
        Date
        Oct 02, 2026
        Transaction ID
        3X812003A5249833K
        Sent to
        @nikolacao
        """

    /// Money in, answering a request. The first line names the *account holder*, not the payer —
    /// `Nikola Cao paid you` — so the name has to come from the second one.
    static let receivedAgainstARequest = """
        ---------- Forwarded message ---------
        From: Venmo < venmo@venmo.com >
        Date: Fri, Oct 2, 2026 at 2:14 PM
        Subject: Michael Vega paid your $23.85 request
        To: < cao.nikola.a@gmail.com >
        Nikola Cao paid you $23.85
        Michael Vega paid you
        $
        23
        .
        85
        Resident evil movie
        See transaction
        Money credited to your Venmo account.
        Transaction details
        Date
        Oct 02, 2026
        Transaction ID
        4699272108450523228
        Sent to
        @nikolacao
        """

    /// Money **out**. Carries the hidden `Patrick guo paid you $386.70` preheader — the opposite
    /// phrasing from the visible `You paid Patrick Guo`.
    static let sent = """
        ---------- Forwarded message ---------
        From: Venmo < venmo@venmo.com >
        Date: Mon, Sep 28, 2026 at 10:07 PM
        Subject: You paid Patrick Guo $386.70
        To: < cao.nikola.a@gmail.com >
        Patrick guo paid you $386.70
        You paid Patrick Guo
        $
        386
        .
        70
        Banff hotel
        See transaction
        Transaction details
        Date
        Sep 28, 2026
        Status
        Completed
        Transaction ID
        4DS54473SS230670Y
        Payment Method
        Venmo balance
        Sent from
        @nikolacao
        """

    static let receivedSmall = """
        ---------- Forwarded message ---------
        From: Venmo < venmo@venmo.com >
        Date: Thu, Sep 24, 2026 at 1:58 PM
        Subject: Patrick Guo paid $6.81 to your Venmo account. Leave it in Venmo or transfer it to your bank account.
        To: < cao.nikola.a@gmail.com >
        Patrick guo paid you $6.81
        Patrick guo paid you
        $
        6
        .
        81
        Haley tried paying for my coffee
        See transaction
        Money credited to your Venmo account.
        Transaction details
        Date
        Sep 24, 2026
        Transaction ID
        1LU93062G7085143D
        Sent to
        @nikolacao
        """

    // MARK: - The same emails as they actually arrive
    //
    // Raw markup, because that is what the registry is handed and it flattens before any parser
    // sees it. The fixtures above are already-flattened, which is what `VenmoAlertParser`
    // itself consumes — but running one of those through `AlertParsers` flattens it a *second*
    // time, and a second pass eats `< venmo@venmo.com >` as though it were a tag.

    private static func markup(body: String) -> String {
        """
        <p>From: Venmo &lt;venmo@venmo.com&gt;</p>
        <p>\(body)</p>
        <div>$</div><div>28</div><span style="display:none">.</span><div>00</div>
        <p>Kimchi red</p><p>See transaction</p>
        <h2>Money credited to your Venmo account.</h2>
        <h3>Date</h3><p>Oct 02, 2026</p>
        """
    }

    static let receivedMarkup = markup(body: "Sarvesh Gade paid you")

    static let sentMarkup = """
        <p>From: Venmo &lt;venmo@venmo.com&gt;</p>
        <p>You paid Patrick Guo</p>
        <div>$</div><div>386</div><span style="display:none">.</span><div>70</div>
        <p>Banff hotel</p><p>See transaction</p>
        <h3>Date</h3><p>Sep 28, 2026</p>
        <h3>Payment Method</h3><p>Venmo balance</p>
        """

    // MARK: - Direction, which is the whole point

    @Test func moneyInBecomesAPositiveDeposit() throws {
        let alert = try #require(VenmoAlertParser.parseFirst(Self.receivedWithNote))

        #expect(alert.isDeposit)
        #expect(alert.amountMinor == 2_800)
        #expect(alert.currencyCode == "USD")
        #expect(alert.cardSuffix.isEmpty)
    }

    @Test func moneyOutBecomesANegativeDeposit() throws {
        let alert = try #require(VenmoAlertParser.parseFirst(Self.sent))

        #expect(alert.isDeposit)
        #expect(alert.amountMinor == -38_670)
    }

    /// The trap, stated as a test. A received payment carries the line `You paid Sarvesh Gade
    /// $28.00` in its hidden preheader. A parser keyed on that phrase would call this money
    /// leaving, which moves the bank the wrong way and still looks entirely plausible.
    @Test func aReceivedPaymentCarriesItsOppositePhrasingAndIsStillMoneyIn() throws {
        #expect(Self.receivedWithNote.contains("You paid Sarvesh Gade $28.00"))

        let alert = try #require(VenmoAlertParser.parseFirst(Self.receivedWithNote))
        #expect(alert.amountMinor > 0, "the hidden preheader must not flip the sign")
    }

    /// And the mirror: a *sent* payment carries `Patrick guo paid you $386.70`.
    @Test func aSentPaymentCarriesItsOppositePhrasingAndIsStillMoneyOut() throws {
        #expect(Self.sent.contains("Patrick guo paid you $386.70"))

        let alert = try #require(VenmoAlertParser.parseFirst(Self.sent))
        #expect(alert.amountMinor < 0, "the hidden preheader must not flip the sign")
    }

    // MARK: - Merchant

    @Test func theMerchantNamesThePersonAndTheNote() throws {
        #expect(try #require(VenmoAlertParser.parseFirst(Self.receivedWithNote)).merchant
                == "Venmo: Sarvesh Gade - Kimchi red")
        #expect(try #require(VenmoAlertParser.parseFirst(Self.sent)).merchant
                == "Venmo: Patrick Guo - Banff hotel")
        #expect(try #require(VenmoAlertParser.parseFirst(Self.receivedSmall)).merchant
                == "Venmo: Patrick guo - Haley tried paying for my coffee")
    }

    /// The payer, not the account holder. `Nikola Cao paid you $23.85` is the first line of
    /// that email and names the wrong person entirely.
    @Test func theNameComesFromTheVisibleLineNotTheFirstOne() throws {
        let alert = try #require(VenmoAlertParser.parseFirst(Self.receivedAgainstARequest))
        #expect(alert.merchant == "Venmo: Michael Vega - Resident evil movie")
    }

    // MARK: - Date

    @Test func theDateIsTheTransactionsNotTheEmails() throws {
        let alert = try #require(VenmoAlertParser.parseFirst(Self.receivedWithNote))
        let occurredAt = try #require(alert.occurredAt)

        let calendar = Calendar.current
        // `Oct 02, 2026` — the transaction field. The forwarded header says `Fri, Oct 2` too,
        // but on the sent email the two differ in shape and this is the one that must win.
        #expect(calendar.component(.year, from: occurredAt) == 2026)
        #expect(calendar.component(.month, from: occurredAt) == 10)
        #expect(calendar.component(.day, from: occurredAt) == 2)
        // A date with no time, so noon — the convention every date-only source here uses.
        #expect(calendar.component(.hour, from: occurredAt) == 12)
    }

    @Test func theDateIsReadPerEmail() throws {
        let calendar = Calendar.current
        let september = try #require(VenmoAlertParser.parseFirst(Self.sent).flatMap(\.occurredAt))
        #expect(calendar.component(.month, from: september) == 9)
        #expect(calendar.component(.day, from: september) == 28)
    }

    // MARK: - Refusing rather than guessing

    /// No direction marker at all: an unrecognised Venmo template. A missing row is recoverable
    /// for a week; a wrong sign is a wrong number.
    @Test func aBodyWithNoDirectionMarkerIsRefused() {
        let body = """
            From: Venmo < venmo@venmo.com >
            Sarvesh Gade paid you
            $
            28
            .
            00
            Kimchi red
            See transaction
            Date
            Oct 02, 2026
            """
        #expect(VenmoAlertParser.parseAll(body).isEmpty)
    }

    /// The envelope. `Payment Method` alone is generic enough to turn up in an order
    /// confirmation, and the Amex automation has already shown these filters over-capture.
    @Test func aBodyNotFromVenmoIsRefused() {
        #expect(VenmoAlertParser.parseAll("Your order shipped. Payment Method: Visa").isEmpty)
    }

    /// The hundredfold error, refused. `$` `28` `00` with the decimal point gone reads as
    /// `$2800` if joined blindly, and both readings are real amounts — so neither is chosen.
    @Test func anAmountWithNoDecimalPointIsRefusedRatherThanJoined() {
        let body = Self.receivedWithNote.replacingOccurrences(of: "\n.\n", with: "\n")
        #expect(body.contains("28\n00"))
        #expect(VenmoAlertParser.parseAll(body).isEmpty)
    }

    /// A single group of digits is unambiguous, so a whole-dollar rendering still parses.
    @Test func aWholeDollarAmountIsStillAccepted() throws {
        let body = Self.receivedWithNote
            .replacingOccurrences(of: "$\n28\n.\n00", with: "$\n500")
        let alert = try #require(VenmoAlertParser.parseAll(body).first)
        #expect(alert.amountMinor == 50_000)
    }

    @Test func theOtherSourcesAreNotClaimed() {
        let fidelity = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
            + "$2.50 at BREEZE*00HS5MV."
        #expect(VenmoAlertParser.parseAll(fidelity).isEmpty)

        let manual = "Manual | charge | 2.50 | 2026-09-23 | 7224 | PUBLIX"
        #expect(VenmoAlertParser.parseAll(manual).isEmpty)
    }

    /// And the other way round: a Venmo body must not be claimed by the manual parser, which
    /// would find nothing anyway — but the registry's first-match-wins order is what keeps a
    /// Venmo email out of the manual path entirely.
    @Test func theRegistryRoutesAVenmoBodyToVenmo() throws {
        let alerts = AlertParsers.parseAll(Self.receivedWithNote)
        #expect(alerts.count == 1)
        #expect(alerts.first?.isDeposit == true)
        #expect(alerts.first?.parserVersion == VenmoAlertParser.version)
    }

    /// Raw markup through the registry, which is the only route that matters: it flattens
    /// first, so this is the shape the flattener actually produces being read by the parser.
    @Test func theRegistryHandlesRawMarkup() throws {
        let received = try #require(AlertParsers.parseFirst(Self.receivedMarkup))
        #expect(received.amountMinor == 2_800)
        #expect(received.merchant == "Venmo: Sarvesh Gade - Kimchi red")
        #expect(received.occurredAt != nil)

        let sent = try #require(AlertParsers.parseFirst(Self.sentMarkup))
        #expect(sent.amountMinor == -38_670)
        #expect(sent.merchant == "Venmo: Patrick Guo - Banff hotel")
    }

    /// A body flattened twice loses the header address, because the second pass reads
    /// `< venmo@venmo.com >` as a tag. A received payment still gets through on the credited
    /// line; a sent one has nothing left to identify it by, so it is refused. Worth pinning
    /// down: it is the difference between the real pipeline and a re-flattened body.
    @Test func aSentBodyLosesItsOnlyEnvelopeWhenFlattenedTwice() {
        let once = HTMLText.extract(from: Self.sentMarkup)
        #expect(VenmoAlertParser.parseFirst(once) != nil)

        let twice = HTMLText.extract(from: once)
        #expect(!twice.contains("venmo@venmo.com"))
        #expect(VenmoAlertParser.parseFirst(twice) == nil)
    }
}
