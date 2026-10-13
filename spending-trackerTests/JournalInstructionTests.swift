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

    // MARK: - The card balance

    @Test(arguments: [0, 24_000, -12_050, 100_000_000_000])
    func everyCardBalanceRoundTrips(_ minor: Int) {
        let line = JournalInstructionParser.composeCardBalance(minor)
        #expect(JournalInstructionParser.parse(line) == .setCardBalance(minor: minor), "\(line)")
    }

    @Test func aCardLineIsRecognisableByEye() {
        #expect(JournalInstructionParser.composeCardBalance(24_000) == "Card | 240.00")
    }

    /// A card in credit is a real balance rather than a typo, which is why this line is signed
    /// like the bank one. It is also the sign the charge rows carry, so a typed balance and the
    /// charges it supersedes cannot disagree about which way round the number goes.
    @Test func aNegativeCardBalanceIsACreditAndNotARejection() {
        #expect(JournalInstructionParser.parse("Card | -120.50") == .setCardBalance(minor: -12_050))
    }

    @Test(arguments: ["Card", "Card |", "Card | abc", "Card | 2,50", "CARD | 1.00 | x"])
    func malformedCardLinesAreRejected(_ text: String) {
        #expect(JournalInstructionParser.parse(text) == nil, "accepted \(text)")
    }

    /// The two balances are told apart by their leading word and by nothing else, so a line
    /// written for one must never be read as the other. A `Card` line that set the bank — or a
    /// `Bank` line that set what is owed — would be a wrong figure with a correct-looking line
    /// in the journal behind it, which is the worst shape a bug can take here.
    @Test func theTwoBalanceLinesAreNotInterchangeable() {
        #expect(JournalInstructionParser.parse("Bank | 10.00") == .setBankBalance(minor: 1_000))
        #expect(JournalInstructionParser.parse("Card | 10.00") == .setCardBalance(minor: 1_000))
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

    // MARK: - Categories

    @Test func aCategoryOnOneRowRoundTrips() throws {
        let line = JournalInstructionParser.composeCategory(occurrenceKey: key, label: "grocery")

        guard case .category(let category)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(category.occurrenceKey == key)
        #expect(category.label == "grocery")
        #expect(category.source == .user)
    }

    /// The one that has to be told apart from "no line at all". Absent means a rule may still
    /// apply; this means none may — otherwise a single row could never be taken out of a rule
    /// the user set on purpose.
    @Test func anExplicitClearIsNotAMissingValue() throws {
        let line = JournalInstructionParser.composeCategory(occurrenceKey: key, label: nil)

        guard case .category(let category)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(category.label == nil)
        #expect(JournalInstructionParser.parse(line) != nil, "a clear must still parse")
    }

    @Test func aMerchantRuleRoundTrips() throws {
        let line = JournalInstructionParser.composeMerchantCategory(
            merchant: "WHOLE FOODS MKT #12", label: "grocery", source: .ai)

        guard case .merchantCategory(let rule)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(rule.merchant == "WHOLE FOODS MKT #12")
        #expect(rule.label == "grocery")
        #expect(rule.source == .ai)
    }

    /// The merchant is free text and last, so nothing has to be escaped or rejected.
    @Test func aMerchantRuleMerchantMayContainTheDelimiter() throws {
        let line = JournalInstructionParser.composeMerchantCategory(
            merchant: "ZELLE | FROM | SAM", label: "miscellaneous", source: .user)

        guard case .merchantCategory(let rule)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(rule.merchant == "ZELLE | FROM | SAM")
    }

    @Test(arguments: [
        "Category",
        "Category |",
        "Category | \("E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0") | grocery",
        "Category | E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0 | grocery | nobody",
        "Category | E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0 | Grocery | user",
        "Category | E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0 | two words | user",
        "Category | no-index-at-all | grocery | user",
        "Category |  | grocery | user",
        "Category | E621E1F8-C36C-495A-93FC-0C247A3E6E5F#0 | grocery | user | extra",
    ])
    func malformedCategoryLinesAreRejected(_ text: String) {
        #expect(JournalInstructionParser.parse(text) == nil, "accepted \(text)")
    }

    @Test(arguments: [
        "MerchantCategory",
        "MerchantCategory | grocery | ai",
        "MerchantCategory | grocery | ai | ",
        "MerchantCategory | grocery | | WHOLE FOODS",
        "MerchantCategory | Grocery | ai | WHOLE FOODS",
    ])
    func malformedMerchantRulesAreRejected(_ text: String) {
        #expect(JournalInstructionParser.parse(text) == nil, "accepted \(text)")
    }

    /// A rule naming no merchant would match every row whose key normalised to empty — one line
    /// categorising the whole ledger at once.
    @Test func aMerchantRuleWithNoMerchantIsRejected() {
        #expect(JournalInstructionParser.parse("MerchantCategory | grocery | ai | ") == nil)
    }

    /// Only a person can clear a row. Nothing in the app writes an `ai` clear, so a line saying
    /// so is not a command to be honoured but evidence the line is not what it claims.
    @Test func onlyAPersonCanClearARow() {
        #expect(JournalInstructionParser.parse("Category | \(key) |  | ai") == nil)
        #expect(JournalInstructionParser.parse("Category | \(key) |  | user") != nil)
    }

    /// A token the app has never heard of is still a well-formed token, and has to be — the set
    /// is free to grow, and a line naming a category added later must not become unreadable,
    /// because unreadable is what the retention purge is allowed to discard.
    @Test func aCategoryThisBuildDoesNotKnowIsStillReadable() throws {
        let line = JournalInstructionParser.composeMerchantCategory(
            merchant: "RYANAIR", label: "travel", source: .ai)

        guard case .merchantCategory(let rule)? = JournalInstructionParser.parse(line) else {
            Issue.record("did not parse: \(line)")
            return
        }
        #expect(rule.label == "travel")
        #expect(SpendingCategory.displayName(for: "travel") == "Travel")
        #expect(!SpendingCategory.isKnown("travel"))
    }

    // MARK: - Retention

    /// Every token the app writes to itself, so the purge can keep such a line forever whether
    /// or not this build can read it. A line that fails to parse is exactly the one that must
    /// not be dropped: it holds a decision and no screen can address it.
    @Test func everyPrefixIsRecognisedIncludingAnUnreadableLine() {
        #expect(JournalInstructionParser.hasInstructionPrefix("Bank | 1200.00"))
        #expect(JournalInstructionParser.hasInstructionPrefix("Edit | \(key) | 1.00 |  |  | X"))
        #expect(JournalInstructionParser.hasInstructionPrefix("Category | \(key) | grocery | user"))
        #expect(JournalInstructionParser.hasInstructionPrefix(
            "MerchantCategory | grocery | ai | WHOLE FOODS"))

        // Written by a version whose format this one does not know: unreadable, and still kept
        // forever, because it holds a decision that exists nowhere else.
        let unreadable = "Category | \(key) | grocery | user | something-new"
        #expect(JournalInstructionParser.hasInstructionPrefix(unreadable))
        #expect(JournalInstructionParser.parse(unreadable) == nil)
    }

    @Test func anAlertBodyHasNoInstructionPrefix() {
        #expect(!JournalInstructionParser.hasInstructionPrefix(
            "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE."))
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
