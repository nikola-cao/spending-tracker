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

    // MARK: - Round trip
    //
    // The form writes a line and the drain reads it back, so the property that matters is that
    // nothing is lost or reshaped in between.

    @Test func aComposedLineParsesBackToTheSameCharge() throws {
        let line = ManualEntryParser.compose(
            merchant: "BREEZE*00HS5MV", amount: "2.50", date: day, cardSuffix: "7224")

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

    @Test func theLineIsRecognisableByEye() {
        // A person may be reading the raw journal directly, which is half the reason this is a
        // readable line rather than an opaque encoding.
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "21006")
        #expect(line.hasPrefix("Manual | "))
        #expect(line.contains("14.20"))
        #expect(line.contains("21006"))
        #expect(line.hasSuffix("PUBLIX"))
    }

    // MARK: - The delimiter

    /// The merchant is the last field, so everything after the fourth pipe belongs to it and
    /// nothing has to be escaped or rejected — which matters because it is free text.
    @Test func aMerchantMayContainTheDelimiter() throws {
        let line = ManualEntryParser.compose(
            merchant: "A | B | C", amount: "5.00", date: day, cardSuffix: "21006")

        let alert = try #require(ManualEntryParser.parseFirst(line))

        #expect(alert.merchant == "A | B | C")
        #expect(alert.amountMinor == 500)
    }

    @Test func aMerchantMayContainAnythingElseToo() throws {
        for merchant in ["AT&T*WIRELESS", "AMAZON.COM*MK1A2B3C4", "SHOP ON MAIN", "Café ☕"] {
            let line = ManualEntryParser.compose(
                merchant: merchant, amount: "1.00", date: day, cardSuffix: "7224")
            let alert = try #require(ManualEntryParser.parseFirst(line), "\(merchant)")
            #expect(alert.merchant == merchant)
        }
    }

    // MARK: - Optional fields
    //
    // Only a merchant and an amount are required. An empty field means "not given", which is
    // deliberately a different thing from a field that is present but wrong.

    @Test func theDateMayBeOmitted() throws {
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "7224")

        let alert = try #require(ManualEntryParser.parseFirst(line))

        // No date of its own, so the ledger falls back to the moment the entry was made — the
        // same fallback a Fidelity alert gets, since that carries no date either.
        #expect(alert.occurredAt == nil)
        #expect(alert.amountMinor == 1420)
        #expect(alert.merchant == "PUBLIX")
    }

    @Test func theCardMayBeOmitted() throws {
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "")

        let alert = try #require(ManualEntryParser.parseFirst(line))

        #expect(alert.cardSuffix == "")
        #expect(alert.amountMinor == 1420)
    }

    @Test func bothMayBeOmittedAtOnce() throws {
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "")

        let alert = try #require(ManualEntryParser.parseFirst(line))

        #expect(alert.occurredAt == nil)
        #expect(alert.cardSuffix == "")
        #expect(alert.merchant == "PUBLIX")
    }

    /// A blank date must still occupy its slot. `omittingEmptySubsequences: false` is what
    /// stops the card sliding left into the date position.
    @Test func anOmittedDateStillOccupiesItsField() {
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: nil, cardSuffix: "7224")
        #expect(line == "Manual | 14.20 |  | 7224 | PUBLIX")
    }

    /// The distinction that matters: absent is fine, malformed is not. Treating an unreadable
    /// date as merely absent would quietly turn a typo into a charge dated today.
    @Test func aMalformedDateIsRejected() {
        #expect(ManualEntryParser.parseAll("Manual | 14.20 | 23/09/2026 | 7224 | PUBLIX").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | 14.20 | yesterday | 7224 | PUBLIX").isEmpty)
    }

    @Test func aMerchantAndAnAmountAreStillRequired() {
        #expect(ManualEntryParser.parseAll("Manual |  | 2026-09-23 | 7224 | PUBLIX").isEmpty)
        #expect(ManualEntryParser.parseAll("Manual | 14.20 | 2026-09-23 | 7224 | ").isEmpty)
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
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "14.20", date: day, cardSuffix: "123")
        #expect(ManualEntryParser.parseAll(line).isEmpty)
    }

    // MARK: - Amounts

    @Test func aMalformedAmountIsRejectedRatherThanGuessed() {
        // The same rule as every other source: "2,50" is ambiguous between a decimal comma and
        // a thousands separator, so it is refused rather than read as $250.00.
        let line = ManualEntryParser.compose(
            merchant: "PUBLIX", amount: "2,50", date: day, cardSuffix: "7224")
        #expect(ManualEntryParser.parseAll(line).isEmpty)
    }

    @Test(arguments: [(250, "2.50"), (120499, "1204.99"), (5, "0.05"), (100, "1.00"), (0, "0.00")])
    func amountsRoundTripThroughTheCanonicalDecimal(_ c: (Int, String)) {
        // The form writes the canonical decimal rather than whatever was typed, so this is the
        // conversion that guarantees a saved charge can always be read back.
        #expect(Money.decimalString(fromMinor: c.0) == c.1)
        #expect(Money.minorUnits(from: c.1) == c.0)
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
        #expect(ManualEntryParser.parseAll("Manual | 2.50 | 2026-09-23 | 7224").isEmpty)
    }
}
