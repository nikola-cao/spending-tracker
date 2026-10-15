//
//  FidelityPaymentParserTests.swift
//  spending-trackerTests
//
//  The real payment SMS, verbatim from the user's phone.
//

import Foundation
import Testing
@testable import spending_tracker

struct FidelityPaymentParserTests {

    /// Verbatim from a real capture. The registered mark arrives as U+00AE.
    static let realPayment = "Fidelity\u{00AE} Credit Card: A payment of $316.29 has been posted "
        + "to your account ending in 7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel."

    /// The same message with the date sentence absent. Losing the date costs the row its date
    /// and not the row, so this has to parse.
    static let paymentWithoutDate = "Fidelity\u{00AE} Credit Card: A payment of $316.29 has been "
        + "posted to your account ending in 7224. Msg&Data rates may apply. Reply STOP to cancel."

    /// The charge SMS, which arrives from the same sender under the same preamble.
    static let chargeSms = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
        + "$2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel."

    /// The Amex payment email, which is a payment of a different kind from a different source.
    static let amexPayment = AmexPaymentParserTests.realPayment

    // MARK: - The real thing

    @Test func theRealPaymentReadsBackCorrectly() throws {
        let alert = try #require(FidelityPaymentParser.parseFirst(Self.realPayment))

        #expect(alert.isPayment)
        #expect(!alert.isCharge)
        #expect(!alert.isDeposit)
        #expect(alert.merchant == "Fidelity payment")
        #expect(alert.cardSuffix == "7224")
        #expect(alert.currencyCode == "USD")
        #expect(alert.rawVerb == "paid")
    }

    /// Stored as its effect. The figure Fidelity prints is what was paid; what the ledger needs
    /// is what it took away, and that is what makes the row come off both summaries by summing.
    @Test func theAmountIsStoredNegated() throws {
        let alert = try #require(FidelityPaymentParser.parseFirst(Self.realPayment))
        #expect(alert.amountMinor == -31_629, "the SMS says $316.29")
    }

    /// The SMS prints a real date, unlike the charge alert — so the row reads "Purchased", and
    /// the ledger sorts it into the month it was paid in rather than the month it arrived in.
    @Test func theDateIsThePostedDate() throws {
        let alert = try #require(FidelityPaymentParser.parseFirst(Self.realPayment))
        let occurredAt = try #require(alert.occurredAt)

        let calendar = Calendar.current
        #expect(calendar.component(.year, from: occurredAt) == 2026)
        #expect(calendar.component(.month, from: occurredAt) == 10)
        #expect(calendar.component(.day, from: occurredAt) == 13)
        #expect(calendar.component(.hour, from: occurredAt) == 12, "noon, as a date with no time")
    }

    /// The registry is what the drain actually calls, so the routing is part of the contract.
    @Test func theRegistryRoutesAPaymentToThePaymentParser() throws {
        let alert = try #require(AlertParsers.parseFirst(Self.realPayment))
        #expect(alert.isPayment)
        #expect(alert.merchant == "Fidelity payment")
        #expect(alert.parserVersion == FidelityPaymentParser.version)
    }

    // MARK: - Shape variation that must still parse

    @Test func aMissingDateCostsTheDateAndNotTheRow() throws {
        let alert = try #require(FidelityPaymentParser.parseFirst(Self.paymentWithoutDate))
        #expect(alert.cardSuffix == "7224")
        #expect(alert.amountMinor == -31_629)
        #expect(alert.occurredAt == nil, "no date was stated, so none is claimed")
    }

    /// A relay can inject characters the phone never showed, and neither may lose the payment.
    ///
    /// The zero-width space is the one that depends on the charge parser's normalisation: it is
    /// not whitespace, so `A\u{200B} payment` matches nothing until the character is stripped.
    /// That is what pins this parser's use of the shared `normalize` rather than its own rules.
    ///
    /// The newline is here as the regression it is, not as evidence about normalisation: every
    /// gap in this sentence is `\s+`, which a newline satisfies on its own. The charge parser is
    /// where flattening newlines is load-bearing, because a lazy `.` capture cannot cross one.
    @Test func aRelayInjectedCharacterDoesNotLoseThePayment() throws {
        let withInvisible = Self.realPayment.replacingOccurrences(
            of: "A payment", with: "A\u{200B} payment")
        let withNewline = Self.realPayment.replacingOccurrences(
            of: "has been posted", with: "has\nbeen posted")

        #expect(FidelityPaymentParser.parseFirst(withInvisible)?.amountMinor == -31_629)
        #expect(FidelityPaymentParser.parseFirst(withNewline)?.amountMinor == -31_629)
    }

    /// A space the relay inserted after the symbol costs nothing. Hard adjacency would lose the
    /// whole payment over one character, which is why the charge parser's corpus pins the same
    /// tolerance on the same symbol.
    @Test func aSpaceAfterTheDollarSignIsTolerated() throws {
        let body = Self.realPayment.replacingOccurrences(of: "$316.29", with: "$ 316.29")
        #expect(FidelityPaymentParser.parseFirst(body)?.amountMinor == -31_629)
    }

    /// The sentence's own period replaced by a newline, with the trailer still there. It is a
    /// fixture in the charge parser's corpus for the same relay damage, and this parser refuses
    /// rather than reads if it loses its terminator — so the tolerance is asserted rather than
    /// assumed.
    @Test func aDroppedSentencePeriodIsSurvivedWhenTheTrailerIsIntact() throws {
        let body = Self.realPayment.replacingOccurrences(of: "10/13/2026.", with: "10/13/2026")
        let alert = try #require(FidelityPaymentParser.parseFirst(body))
        #expect(alert.amountMinor == -31_629)
        #expect(alert.cardSuffix == "7224")
    }

    /// Prose in place of the terminator is still a refusal: the tolerance above is for the
    /// alert's own trailer, not for a sentence that simply carries on.
    @Test func proseInsteadOfATerminatorIsRefused() {
        let body = Self.realPayment.replacingOccurrences(
            of: "10/13/2026.", with: "10/13/2026 and then some other words")
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// The registered-mark variants a re-encoding relay produces, which is what the charge
    /// parser's own corpus pins for the same preamble.
    @Test(arguments: [
        "Fidelity\u{00AE} Credit Card: ",
        "Fidelity(R) Credit Card: ",
        "Fidelity\u{00C2}\u{00AE} Credit Card: ",
        "Fidelity Credit Card: ",
    ])
    func thePreambleVariantsAreTolerated(_ preamble: String) {
        let body = preamble + "A payment of $316.29 has been posted to your account ending in "
            + "7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel."
        #expect(FidelityPaymentParser.parseFirst(body)?.amountMinor == -31_629)
    }

    /// Two messages can arrive concatenated with no separator, which is why the charge parser
    /// takes every match. A payment is no different.
    @Test func everyPaymentInAConcatenatedBodyIsRead() {
        let alerts = FidelityPaymentParser.parseAll(Self.realPayment + " " + Self.realPayment)
        #expect(alerts.count == 2)
        #expect(alerts.allSatisfy { $0.amountMinor == -31_629 })
    }

    @Test func aLargerAmountKeepsItsThousands() throws {
        let body = Self.realPayment.replacingOccurrences(of: "$316.29", with: "$1,204.99")
        let alert = try #require(FidelityPaymentParser.parseFirst(body))
        #expect(alert.amountMinor == -120_499)
    }

    // MARK: - Refusing rather than reaching for a number

    /// Neither Fidelity sentence may be read as the other. The charge text arrives from the same
    /// sender under the same preamble and carries a figure of its own, so a body read by both
    /// parsers would be one movement of money counted twice. Both refusals are asserted here as
    /// a pair rather than argued; the charge parser's own corpus pins the same property from its
    /// side.
    @Test func neitherFidelitySentenceIsReadAsTheOther() {
        #expect(FidelityPaymentParser.parseAll(Self.chargeSms).isEmpty)
        #expect(FidelityAlertParser.parseAll(Self.realPayment).isEmpty)

        // And through the registry each is still claimed by its own parser.
        let charge = AlertParsers.parseFirst(Self.chargeSms)
        #expect(charge?.isCharge == true)
        #expect(charge?.isPayment == false)
    }

    /// `account ending in` is ordinary banking English that any issuer may print, so the
    /// Fidelity preamble is required alongside it rather than the sentence standing alone.
    @Test func aBodyWithNoPreambleIsRefused() {
        let body = "A payment of $316.29 has been posted to your account ending in 7224 on "
            + "10/13/2026. Msg&Data rates may apply. Reply STOP to cancel."
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// A posted *debit* is a different alert about a different thing, and the same portal offers
    /// it. Only the literal `A payment of` may be read as a payment.
    @Test func aPostedDebitIsNotAPayment() {
        let body = "Fidelity\u{00AE} Credit Card: A debit of $316.29 has been posted to your "
            + "account ending in 7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel."
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// A payment that has been authorised has not posted — the money has not moved yet, and
    /// recording it would double the payment when the posted alert followed.
    @Test func anAuthorizationIsNotAPostedPayment() {
        let body = "Fidelity\u{00AE} Credit Card: A payment of $316.29 has been authorized to "
            + "your account ending in 7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel."
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// An amount outside the shared cap is refused outright rather than recorded as a wrong
    /// number — the trade this project makes everywhere a figure is read.
    @Test func anAmountOutsideTheCapRefusesTheRowRatherThanRecordingIt() {
        let body = Self.realPayment.replacingOccurrences(of: "$316.29", with: "$10,000,000,000.00")
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// A figure that is not a whole amount is a broken parse, not a payment.
    @Test func aMalformedAmountIsRefused() {
        let body = Self.realPayment.replacingOccurrences(of: "$316.29", with: "$316.295")
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// The charge parser has this at the card capture, and it matters for the same reason: ICU's
    /// `\d` matches any Unicode decimal digit, so a card number in another script would be
    /// captured and could never equal a real card.
    @Test func arabicIndicCardDigitsAreRefused() {
        let body = Self.realPayment.replacingOccurrences(of: "7224", with: "\u{0667}\u{0662}\u{0662}\u{0664}")
        #expect(FidelityPaymentParser.parseAll(body).isEmpty)
    }

    /// A date the strict formatter cannot read is refused rather than rolled forward or swapped,
    /// and the row survives on its arrival time — which is the honest answer, and the whole
    /// reason the date is captured loosely and validated afterwards: a corrupted day must not
    /// take the amount and the card down with it.
    @Test(arguments: ["13/10/2026", "02/30/2026", "00/00/0000", "1O/13/2026", "10/13/20"])
    func anUnreadableDateCostsTheDateAndNotTheRow(_ date: String) throws {
        let body = Self.realPayment.replacingOccurrences(of: "10/13/2026", with: date)
        let alert = try #require(FidelityPaymentParser.parseFirst(body))
        #expect(alert.amountMinor == -31_629)
        #expect(alert.cardSuffix == "7224")
        #expect(alert.occurredAt == nil)
    }

    /// A single-digit month and day are read as what they are, not dropped.
    @Test func aSingleDigitDateIsRead() throws {
        let body = Self.realPayment.replacingOccurrences(of: "10/13/2026", with: "1/3/2026")
        let occurredAt = try #require(FidelityPaymentParser.parseFirst(body)?.occurredAt)
        let calendar = Calendar.current
        #expect(calendar.component(.month, from: occurredAt) == 1)
        #expect(calendar.component(.day, from: occurredAt) == 3)
    }

    @Test func theOtherSourcesAreNotClaimed() {
        let venmo = "From: Venmo < venmo@venmo.com >\nParick paid you\n$\n28\n00\nSee transaction\n"
            + "Money credited to your Venmo account.\nDate\nOct 02, 2026"
        #expect(FidelityPaymentParser.parseAll(venmo).isEmpty)

        let manual = "Manual | payment | -825.77 | 2026-10-03 |  | AMEX PAYMENT"
        #expect(FidelityPaymentParser.parseAll(manual).isEmpty)

        // A payment read from an Amex email is a payment, but not this source's, and it still
        // routes to Amex's parser with Amex's merchant.
        #expect(FidelityPaymentParser.parseAll(Self.amexPayment).isEmpty)
        #expect(AlertParsers.parseFirst(Self.amexPayment)?.merchant == "Amex payment")
    }

    // MARK: - The pattern itself

    /// Kept as a string so a dialect problem surfaces here rather than as a silent no-match on
    /// the phone.
    @Test func patternCompiles() {
        #expect(FidelityPaymentParser.regex != nil)
    }

    /// Guards the property that makes the journal replayable: parsing is a pure function of the
    /// raw text, so the same input always yields the same result.
    @Test func parsingIsPureAndRepeatable() {
        let first = FidelityPaymentParser.parseAll(Self.realPayment)
        for _ in 0..<50 {
            #expect(FidelityPaymentParser.parseAll(Self.realPayment) == first)
        }
    }

    /// `parseFirst` must agree with `parseAll` — the ledger will use one and the UI the other.
    @Test func parseFirstAgreesWithParseAll() {
        for body in [Self.realPayment, Self.paymentWithoutDate, Self.chargeSms] {
            #expect(FidelityPaymentParser.parseFirst(body) == FidelityPaymentParser.parseAll(body).first)
        }
    }
}
