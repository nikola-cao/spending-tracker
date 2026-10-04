//
//  ManualEntryParserTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

struct ManualEntryParserTests {

    /// A fixed instant, so the assertions do not depend on when the suite runs.
    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func chargeLine(
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) -> String {
        ManualEntryParser.compose(
            kind: .charge, merchant: merchant, amount: amount, date: date, cardSuffix: cardSuffix)
    }

    private func depositLine(merchant: String, amount: String, date: Date? = nil) -> String {
        ManualEntryParser.compose(
            kind: .deposit, merchant: merchant, amount: amount, date: date, cardSuffix: "")
    }

    // MARK: - Round trip
    //
    // The form writes a line and the drain reads it back, so the property that matters is that
    // nothing is lost or reshaped in between.

    @Test func aComposedLineParsesBackToTheSameCharge() throws {
        let line = chargeLine(merchant: "BREEZE*00HS5MV", amount: "2.50", date: day, cardSuffix: "7224")

        let alert = try #require(ManualEntryParser.parseFirst(line))

        #expect(alert.amountMinor == 250)
        #expect(alert.merchant == "BREEZE*00HS5MV")
        #expect(alert.cardSuffix == "7224")
        #expect(alert.isCharge)
        #expect(alert.currencyCode == "USD")

        // The form takes a date and no time, so the parsed value lands at noon and the
        // calendar day must be unchanged.
        let calendar = Calendar.current
        let parsed = try #require(alert.occurredAt)
        #expect(calendar.component(.day, from: parsed) == calendar.component(.day, from: day))
        #expect(calendar.component(.month, from: parsed) == calendar.component(.month, from: day))
        #expect(calendar.component(.year, from: parsed) == calendar.component(.year, from: day))
    }

    @Test func aComposedLineParsesBackToTheSameDeposit() throws {
        let line = depositLine(merchant: "PAYCHECK", amount: "1500.00", date: day)

        let alert = try #require(ManualEntryParser.parseFirst(line))

        #expect(alert.isDeposit)
        #expect(alert.amountMinor == 150_000)
        #expect(alert.merchant == "PAYCHECK")
        #expect(alert.cardSuffix.isEmpty)
        #expect(alert.occurredAt != nil)
    }

    @Test func theLineIsRecognisableByEye() {
        // A person may be reading the raw journal directly, which is half the reason this is a
        // readable line rather than an opaque encoding.
        let line = chargeLine(merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "21006")
        #expect(line.hasPrefix("Manual | charge | "))
        #expect(line.contains("14.20"))
        #expect(line.contains("21006"))
        #expect(line.hasSuffix("PUBLIX"))

        #expect(depositLine(merchant: "PAYCHECK", amount: "500.00").hasPrefix("Manual | deposit | "))
    }

    // MARK: - The delimiter

    /// The merchant is the last field, so everything after the last pipe belongs to it and
    /// nothing has to be escaped or rejected — which matters because it is free text.
    @Test func aMerchantMayContainTheDelimiter() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(chargeLine(
                merchant: "A | B | C", amount: "5.00", date: day, cardSuffix: "21006")))

        // The spacing inside the merchant survives; splitting on every pipe and re-joining it
        // would quietly rewrite this as "A|B|C".
        #expect(alert.merchant == "A | B | C")
        #expect(alert.amountMinor == 500)
    }

    @Test func aDepositMerchantMayContainTheDelimiterToo() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(depositLine(merchant: "ZELLE | FROM | SAM", amount: "50")))

        #expect(alert.isDeposit)
        #expect(alert.merchant == "ZELLE | FROM | SAM")
    }

    @Test func aMerchantMayContainAnythingElseToo() throws {
        for merchant in ["AT&T*WIRELESS", "AMAZON.COM*MK1A2B3C4", "SHOP ON MAIN", "Café ☕"] {
            let line = chargeLine(merchant: merchant, amount: "1.00", date: day, cardSuffix: "7224")
            let alert = try #require(ManualEntryParser.parseFirst(line), "\(merchant)")
            #expect(alert.merchant == merchant)
        }
    }

    // MARK: - Optional fields
    //
    // Only a merchant and an amount are required. An empty field means "not given", which is
    // deliberately a different thing from a field that is present but wrong.

    @Test func theDateMayBeOmitted() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(
                chargeLine(merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "7224")))

        // No date of its own, so the ledger falls back to the moment the entry was made — the
        // same fallback a Fidelity alert gets, since that carries no date either.
        #expect(alert.occurredAt == nil)
        #expect(alert.amountMinor == 1420)
        #expect(alert.merchant == "PUBLIX")
    }

    @Test func theCardMayBeOmitted() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(
                chargeLine(merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "")))

        #expect(alert.cardSuffix == "")
        #expect(alert.amountMinor == 1420)
    }

    @Test func bothMayBeOmittedAtOnce() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(
                chargeLine(merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "")))

        #expect(alert.occurredAt == nil)
        #expect(alert.cardSuffix == "")
        #expect(alert.merchant == "PUBLIX")
    }

    /// A blank date must still occupy its slot. `omittingEmptySubsequences: false` is what
    /// stops the card sliding left into the date position.
    @Test func anOmittedDateStillOccupiesItsField() {
        let line = chargeLine(merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "7224")
        #expect(line == "Manual | charge | 14.20 |  | 7224 | PUBLIX")

        let deposit = depositLine(merchant: "PAYCHECK", amount: "500.00")
        #expect(deposit == "Manual | deposit | 500.00 |  |  | PAYCHECK")
    }

    /// The distinction that matters: absent is fine, malformed is not. Treating an unreadable
    /// date as merely absent would quietly turn a typo into a charge dated today.
    @Test func aMalformedDateIsRejected() {
        #expect(ManualEntryParser.parseAll("Manual | charge | 14.20 | 23/09/2026 | 7224 | PUBLIX").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | charge | 14.20 | yesterday | 7224 | PUBLIX").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | deposit | 14.20 | 23/09/2026 |  | PUBLIX").isEmpty)
    }

    @Test func aMerchantAndAnAmountAreStillRequired() {
        #expect(ManualEntryParser.parseAll("Manual | charge |  | 2026-09-23 | 7224 | PUBLIX").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | charge | 14.20 | 2026-09-23 | 7224 | ").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | deposit | 14.20 | 2026-09-23 |  | ").isEmpty)
    }

    // MARK: - Signs
    //
    // Both kinds are signed. A refund is a negative charge, and a deposit goes whichever way
    // the money did.

    @Test func aChargeMayBeNegativeForARefund() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(
                chargeLine(merchant: "AMAZON REFUND", amount: "-12.00", date: day, cardSuffix: "7224")))

        #expect(alert.amountMinor == -1200)
        #expect(alert.isCharge)
    }

    @Test func aDepositMayBeNegativeForMoneyGoingOut() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(depositLine(merchant: "RENT", amount: "-1500.00")))

        #expect(alert.amountMinor == -150_000)
        #expect(alert.isDeposit)
    }

    @Test(arguments: ["-12.00", "12.00", "-0.05", "0.00"])
    func signedAmountsRoundTripThroughTheJournal(_ amount: String) throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(chargeLine(
                merchant: "SIGNED", amount: amount, date: nil, cardSuffix: "")))
        #expect(Money.decimalString(fromMinor: alert.amountMinor) == amount)
    }

    /// `Money.minorUnits` — the one the alert parsers use — still refuses a minus. Only a
    /// person typing gets one, so a captured message can never smuggle in a negative charge.
    @Test func theStrictParserStillRefusesAMinus() {
        #expect(Money.minorUnits(from: "-12.00") == nil)
        #expect(Money.signedMinorUnits(from: "-12.00") == -1200)
    }

    // MARK: - Card digits

    @Test(arguments: ["1234", "12345"])
    func fourOrFiveDigitsAreAccepted(_ value: String) {
        #expect(ManualEntryParser.isValidCardSuffix(value))
    }

    @Test(arguments: ["123", "123456", "", " 1234", "12a4", "12 34", "abcd", "\u{FF11}\u{FF12}\u{FF13}\u{FF14}"])
    func anythingElseIsRejected(_ value: String) {
        // The last case is FULLWIDTH DIGIT ONE..FOUR: `Character.isNumber` is true for those,
        // so a naive check accepts them and they then never match a captured suffix.
        #expect(!ManualEntryParser.isValidCardSuffix(value), "accepted \(value)")
    }

    @Test func aLineWithABadCardIsRejected() {
        #expect(ManualEntryParser.parseAll(
            chargeLine(merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "123")).isEmpty)
    }

    /// A deposit has no card, so one on the line is malformed rather than something to quietly
    /// drop — dropping it would accept a line the format says cannot exist.
    @Test func aDepositLineNamingACardIsRejected() {
        #expect(ManualEntryParser.parseAll(
            "Manual | deposit | 500.00 | 2026-09-23 | 7224 | PAYCHECK").isEmpty)
    }

    // MARK: - Amounts

    @Test func aMalformedAmountIsRejectedRatherThanGuessed() {
        // The same rule as every other source: "2,50" is ambiguous between a decimal comma and
        // a thousands separator, so it is refused rather than read as $250.00.
        #expect(ManualEntryParser.parseAll(
            chargeLine(merchant: "PUBLIX", amount: "2,50", date: day, cardSuffix: "7224")).isEmpty)
    }

    @Test(arguments: [(250, "2.50"), (120499, "1204.99"), (5, "0.05"), (100, "1.00"), (0, "0.00")])
    func amountsRoundTripThroughTheCanonicalDecimal(_ c: (Int, String)) {
        // The form writes the canonical decimal rather than whatever was typed, so this is the
        // conversion that guarantees a saved charge can always be read back.
        #expect(Money.decimalString(fromMinor: c.0) == c.1)
        #expect(Money.minorUnits(from: c.1) == c.0)
    }

    // MARK: - Payments

    private func paymentLine(merchant: String, amount: String, date: Date? = nil) -> String {
        ManualEntryParser.compose(
            kind: .payment, merchant: merchant, amount: amount, date: date, cardSuffix: "")
    }

    /// A payment is stored as its effect, so the line carries a negative amount even though the
    /// figure a person types is what they paid.
    @Test func aPaymentRoundTripsWithItsStoredSign() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst(paymentLine(merchant: "AMEX PAYMENT", amount: "-825.77")))

        #expect(alert.isPayment)
        #expect(!alert.isDeposit)
        #expect(!alert.isCharge)
        #expect(alert.amountMinor == -82_577)
        #expect(alert.merchant == "AMEX PAYMENT")
        #expect(alert.cardSuffix.isEmpty)
    }

    /// A payment has no card, the same as a deposit — so a line naming one is malformed rather
    /// than something to quietly drop.
    @Test func aPaymentLineNamingACardIsRejected() {
        #expect(ManualEntryParser.parseAll(
            "Manual | payment | -825.77 | 2026-10-03 | 21006 | AMEX PAYMENT").isEmpty)
    }

    /// The three kinds are told apart by the field, and only one of them takes a card.
    @Test func theThreeKindsAreDistinct() throws {
        #expect(try #require(
            ManualEntryParser.parseFirst(chargeLine(
                merchant: "X", amount: "1.00", date: nil, cardSuffix: "7224"))).isCharge)
        #expect(try #require(
            ManualEntryParser.parseFirst(depositLine(merchant: "X", amount: "1.00"))).isDeposit)
        #expect(try #require(
            ManualEntryParser.parseFirst(paymentLine(merchant: "X", amount: "-1.00"))).isPayment)
    }

    @Test func theLedgerEntryKindsAllCount() {
        #expect(ParsedAlert.Kind.charge.isLedgerEntry)
        #expect(ParsedAlert.Kind.deposit.isLedgerEntry)
        #expect(ParsedAlert.Kind.payment.isLedgerEntry)
        #expect(!ParsedAlert.Kind.unrecognizedVerb.isLedgerEntry)
    }

    // MARK: - The older shape

    /// The journal is append-only, so lines written before the kind field existed have to keep
    /// meaning what they meant when they were written: a charge.
    @Test func aLineFromBeforeTheKindFieldStillParsesAsACharge() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst("Manual | 14.20 | 2026-09-23 | 7224 | PUBLIX"))

        #expect(alert.isCharge)
        #expect(alert.amountMinor == 1420)
        #expect(alert.merchant == "PUBLIX")
        #expect(alert.cardSuffix == "7224")
    }

    /// And the old shape with the merchant holding a pipe, which is exactly the case a
    /// one-split-for-both-formats reader would have broken.
    @Test func anOlderLineWithAPipeInTheMerchantStillParses() throws {
        let alert = try #require(
            ManualEntryParser.parseFirst("Manual | 5.00 | 2026-09-23 | 21006 | A | B"))

        #expect(alert.isCharge)
        #expect(alert.merchant == "A | B")
        #expect(alert.amountMinor == 500)
    }

    /// A legacy line has its amount where a new line has its kind, and an amount is never
    /// spelled "charge" — which is the whole reason the two can be told apart.
    @Test func theKindFieldIsNotConfusedWithAnAmount() {
        // "charge" is not a number, so this is a new-shape line missing its amount.
        #expect(ManualEntryParser.parseAll("Manual | charge |  | 2026-09-23 | 7224 | PUBLIX").isEmpty)
        // An unrecognised verb is not something a person can type.
        #expect(ManualEntryParser.parseAll(
            "Manual | unrecognizedVerb | 5.00 | 2026-09-23 | 7224 | PUBLIX").isEmpty)
    }

    // MARK: - Staying out of the way of the other sources

    @Test func aCapturedAlertIsNotClaimed() {
        let fidelity = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
            + "$2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel."
        #expect(ManualEntryParser.parseAll(fidelity).isEmpty)
    }

    @Test func anEmptyBodyIsRejected() {
        #expect(ManualEntryParser.parseAll("").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | 2.50").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | charge | 2.50").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | 2.50 | 2026-09-23 | 7224").isEmpty)
    }
}
