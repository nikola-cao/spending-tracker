//
//  LedgerStoreTests.swift
//  spending-trackerTests
//

import Foundation
import SwiftData
import Testing
@testable import spending_tracker

@MainActor
struct LedgerStoreTests {

    private let trailer = " Msg&Data rates may apply. Reply STOP to cancel."

    private func charge(_ amount: String, _ merchant: String, last4: String = "7224") -> String {
        "Fidelity\u{00AE} Credit Card: Your card ending in \(last4) was charged $\(amount) at \(merchant).\(trailer)"
    }

    private func tempJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "st3-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    /// Mirrors what `LogTransactionIntent` writes: an `enter`/`result` pair per alert, both
    /// carrying the same body.
    private func writeJournal(_ bodies: [String], to url: URL) throws {
        for body in bodies {
            let runID = UUID()
            try JournalStore.append(.diagnostic(runID: runID, phase: "enter", raw: body, note: ""), to: url)
            try JournalStore.append(.diagnostic(runID: runID, phase: "result", raw: body, note: "ok"), to: url)
        }
    }

    /// The container is held by the test as well as the store, so assertions can read what
    /// was actually persisted rather than trusting the store's own counters.
    private func makeStore() throws -> (ledger: LedgerStore, container: ModelContainer, url: URL) {
        let container = try ModelContainer(
            for: Schema([AlertEvent.self, Txn.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let url = tempJournalURL()
        return (LedgerStore(container: container, journalURL: url), container, url)
    }

    private func txns(_ container: ModelContainer) -> [Txn] {
        (try? container.mainContext.fetch(FetchDescriptor<Txn>())) ?? []
    }

    private func events(_ container: ModelContainer) -> [AlertEvent] {
        (try? container.mainContext.fetch(FetchDescriptor<AlertEvent>())) ?? []
    }

    // MARK: - The happy path

    @Test func oneAlertBecomesOneEventAndOneTransaction() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal([charge("2.50", "BREEZE*00HS5MV")], to: url)

        let result = ledger.drain()

        // Two journal lines (enter + result) collapse to ONE event — they carry the same
        // body, which is exactly why the hash is taken over the raw text.
        #expect(result.recordsRead == 2)
        #expect(result.eventsAdded == 1)
        #expect(result.transactionsAdded == 1)
        #expect(events(container).count == 1)
        #expect(txns(container).count == 1)
    }

    @Test func amountAndMerchantSurviveTheWholePipeline() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal([charge("1,204.99", "AT&T*WIRELESS PMT")], to: url)
        ledger.drain()

        let stored = try #require(txns(container).first)
        #expect(stored.amountMinor == 120499)
        #expect(stored.merchant == "AT&T*WIRELESS PMT")
        #expect(stored.cardLast4 == "7224")
        #expect(stored.currencyCode == "USD")
        #expect(stored.formattedAmount == "$1,204.99")
        #expect(stored.possibleDuplicate == false)
    }

    /// Every foreground re-runs the drain, so repeating it must change nothing.
    @Test func drainIsIdempotent() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal([charge("2.50", "A"), charge("31.79", "B")], to: url)

        let first = ledger.drain()
        #expect(first.eventsAdded == 2)

        let second = ledger.drain()
        #expect(second.eventsAdded == 0)
        #expect(second.transactionsAdded == 0)
        #expect(events(container).count == 2)
        #expect(txns(container).count == 2)
    }

    @Test func drainingAnEmptyJournalIsHarmless() throws {
        let (ledger, _, _) = try makeStore()
        #expect(ledger.drain() == LedgerStore.DrainResult())
    }

    // MARK: - What must NOT reach the ledger

    @Test func unreadableBodyKeepsTheEventButDerivesNoTransaction() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal(["Your Uber code is 1234"], to: url)

        let result = ledger.drain()

        // The raw text is kept — that is what makes a later parser fix able to recover it.
        #expect(result.eventsAdded == 1)
        #expect(result.needsReview == 1)
        #expect(result.transactionsAdded == 0)
        #expect(events(container).count == 1)
        #expect(txns(container).isEmpty)
        #expect(events(container).first?.transaction == nil)
        #expect(events(container).first?.parseState == .needsReview)
    }

    @Test func nonChargeVerbIsKeptForReviewAndNotLedgered() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal(
            ["Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4." + trailer],
            to: url
        )

        let result = ledger.drain()

        // It parses, but it is not a charge, so it must not reach the ledger. That invariant —
        // "Txn contains only charges" — is what lets the feed query need no predicate, and a
        // forgotten predicate is how unparsed rows would silently pollute a total.
        #expect(result.needsReview == 1)
        #expect(result.transactionsAdded == 0)
        #expect(txns(container).isEmpty)
    }

    /// The intent journals a rejected empty invocation with a note rather than dropping it.
    /// That record must not become an event.
    @Test func emptyBodiesAreSkippedEntirely() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal(["", "   "], to: url)

        let result = ledger.drain()

        #expect(result.eventsAdded == 0)
        #expect(events(container).isEmpty)
    }

    // MARK: - Duplicates

    @Test func aNearIdenticalChargeIsFlaggedButNeverMerged() throws {
        let (ledger, container, url) = try makeStore()
        // Two DIFFERENT bodies (so different hashes) describing the same card, amount and
        // merchant. A byte-identical redelivery is already dropped by the hash; this is the
        // pair the hash cannot catch.
        try writeJournal([
            charge("2.50", "BREEZE*00HS5MV"),
            "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV.",
        ], to: url)

        ledger.drain()

        let stored = txns(container)
        #expect(stored.count == 2, "two real charges must never be silently merged into one")
        #expect(stored.filter(\.possibleDuplicate).count == 1, "exactly one should be flagged")
    }

    @Test func distinctChargesAreNotFlagged() throws {
        let (ledger, container, url) = try makeStore()
        try writeJournal([
            charge("2.50", "BREEZE*00HS5MV"),
            charge("5.30", "DEEPSEERWEA"),
            charge("2.50", "SOME OTHER MERCHANT"),
        ], to: url)

        ledger.drain()

        #expect(txns(container).count == 3)
        #expect(txns(container).filter(\.possibleDuplicate).isEmpty)
    }

    // MARK: - Hashing

    @Test func contentHashIsStableAndDistinguishing() {
        let body = charge("2.50", "BREEZE*00HS5MV")
        #expect(LedgerStore.contentHash(body) == LedgerStore.contentHash(body))
        #expect(LedgerStore.contentHash(body) != LedgerStore.contentHash(charge("2.51", "BREEZE*00HS5MV")))
        #expect(LedgerStore.contentHash(body).count == 64)
    }
}
