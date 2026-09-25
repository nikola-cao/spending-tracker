//
//  JournalInstructionTests.swift
//  spending-trackerTests
//
//  The lines the app writes to its own journal. They carry no source text, so nothing else
//  would catch it if the writer and the reader disagreed about their shape.
//

import Foundation
import Testing
@testable import spending_tracker

struct JournalInstructionTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)
    private let key = "E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0"

    // MARK: - The bank balance

    @Test(arguments: [0, 12_345, -4_000, 100_000_000_000])
    func everyBalanceRoundTrips(_ minor: Int) {
        let line = JournalInstructionParser.composeBankBalance(minor)
        #expect(JournalInstructionParser.parse(line) == .setBankBalance(minor: minor), "\(line)")
    }

    @Test func aBalanceLineIsRecognisableByEye() {
        #expect(JournalInstructionParser.composeBankBalance(120_000) == "Bank | 1200.00")
    }

    @Test(arguments: ["Bank", "Bank |", "Bank | abc", "Bank | 2,50", "BANK | 1.00 | x"])
    func malformedBalanceLinesAreRejected(_ text: String) {
        #expect(JournalInstructionParser.parse(text) == nil, "accepted \(text)")
    }

    // MARK: - Edits

    @Test func anEditRoundTrips() throws {
        let line = JournalInstructionParser.composeEdit(
            occurrenceKey: key, merchant: "BREEZE COFFEE", amount: "4.00", date: day,
            cardSuffix: "7224")

        guard case .edit(let edit)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(edit.occurrenceKey == key)
        #expect(edit.amountMinor == 400)
        #expect(edit.merchant == "BREEZE COFFEE")
        #expect(edit.cardSuffix == "7224")

        let occurredAt = try #require(edit.occurredAt)
        #expect(Calendar.current.isDate(occurredAt, inSameDayAs: day))
        #expect(Calendar.current.component(.hour, from: occurredAt) == 12)
    }

    /// The regression. A guard checked the card field for emptiness instead of the merchant,
    /// which rejected every edit to a row with no card — every deposit among them — and looked
    /// exactly like the edit saving and then not applying.
    @Test func anEditOfARowWithNoCardIsAccepted() throws {
        for merchant in ["ZELLE FROM SAM", "PAYCHECK"] {
            let line = JournalInstructionParser.composeEdit(
                occurrenceKey: key, merchant: merchant, amount: "25.00", date: nil, cardSuffix: "")

            guard case .edit(let edit)? = JournalInstructionParser.parse(line) else {
                Issue.record("did not parse: \(line)")
                return
            }
            #expect(edit.cardSuffix.isEmpty)
            #expect(edit.merchant == merchant)
            #expect(edit.occurredAt == nil)
        }
    }

    @Test func anEditMerchantMayContainTheDelimiter() throws {
        let line = JournalInstructionParser.composeEdit(
            occurrenceKey: key, merchant: "ZELLE | FROM | SAM", amount: "25.00", date: nil,
            cardSuffix: "")

        guard case .edit(let edit)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(edit.merchant == "ZELLE | FROM | SAM")
    }

    @Test func anEditMayBeNegative() throws {
        let line = JournalInstructionParser.composeEdit(
            occurrenceKey: key, merchant: "AMAZON REFUND", amount: "-12.00", date: nil,
            cardSuffix: "7224")

        guard case .edit(let edit)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(edit.amountMinor == -1200)
    }

    @Test func anEditWithNoMerchantIsRejected() {
        #expect(JournalInstructionParser.parse("Edit | \(key) | 4.00 |  | 7224 | ") == nil)
    }

    @Test func anEditWithABadDateIsRejected() {
        // Absent is fine, unreadable is not — the same rule every other line holds.
        #expect(JournalInstructionParser.parse("Edit | \(key) | 4.00 | 23/09/2026 |  | X") == nil)
    }

    @Test func anEditWithABadCardIsRejected() {
        #expect(JournalInstructionParser.parse("Edit | \(key) | 4.00 |  | 123 | X") == nil)
    }

    // MARK: - Staying out of the alert path

    /// These lines must never be mistaken for an alert, or a mis-parse becomes a fake charge.
    @Test func anInstructionIsNotAnAlert() {
        let bank = JournalInstructionParser.composeBankBalance(120_000)
        let edit = JournalInstructionParser.composeEdit(
            occurrenceKey: key, merchant: "X", amount: "1.00", date: nil, cardSuffix: "")

        #expect(AlertParsers.parseAll(bank).isEmpty)
        #expect(AlertParsers.parseAll(edit).isEmpty)
    }

    @Test func anAlertIsNotAnInstruction() {
        let fidelity = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
            + "$2.50 at BREEZE*00HS5MV."
        #expect(JournalInstructionParser.parse(fidelity) == nil)
        #expect(!JournalInstructionParser.isInstruction(fidelity))
    }
}
