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

    /// Writes one alert the way `LogTransactionIntent` does: an `enter`/`result` pair sharing
    /// a single `runID`. The runID is the occurrence identity the ledger dedupes on, so tests
    /// control it explicitly.
    private func appendAlert(_ body: String, runID: UUID = UUID(), to url: URL) throws {
        try JournalStore.append(.diagnostic(runID: runID, phase: "enter", raw: body, note: ""), to: url)
        try JournalStore.append(.diagnostic(runID: runID, phase: "result", raw: body, note: "ok"), to: url)
    }

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

    // MARK: - The regression that motivated occurrence-keyed dedup

    /// A Fidelity body is a pure function of (card, amount, merchant) — no transaction id, no
    /// timestamp — so a monthly subscription produces a byte-identical string every month.
    /// Deduping on the body recorded the first month and silently discarded every one after.
    @Test func theSameChargeRepeatedIsRecordedEveryTime() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("15.49", "NETFLIX.COM")

        // Three separate invocations, identical bodies — one per month.
        for _ in 0..<3 {
            try appendAlert(body, to: url)
        }

        ledger.drain()

        #expect(txns(container).count == 3, "a repeat charge must never be treated as a redelivery")
    }

    /// The other half of the same coin: a redelivery of ONE alert — the enter/result pair —
    /// must still collapse to a single row.
    @Test func theEnterResultPairCollapsesToOneRow() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)

        let result = ledger.drain()

        #expect(result.recordsRead == 2, "the pair is two journal lines")
        #expect(result.eventsAdded == 1, "but one alert")
        #expect(txns(container).count == 1)
    }

    // MARK: - One body, more than one alert

    /// Bodies have been observed carrying two alerts concatenated with no separator. The
    /// parser finds both; the ledger must not quietly keep only the first.
    @Test func aBodyCarryingTwoAlertsProducesTwoTransactions() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("36.00", "Georgia Tech Parking S") + charge("73.00", "CENTRAL ROCK MID (ATL)")
        try appendAlert(body, to: url)

        ledger.drain()

        let stored = txns(container)
        #expect(stored.count == 2)
        #expect(Set(stored.map(\.amountMinor)) == [3600, 7300])
        #expect(events(container).count == 2)
        #expect(Set(events(container).map(\.matchIndex)) == [0, 1])
    }

    // MARK: - The happy path

    @Test func amountAndMerchantSurviveTheWholePipeline() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("1,204.99", "AT&T*WIRELESS PMT"), to: url)

        ledger.drain()

        let stored = try #require(txns(container).first)
        #expect(stored.amountMinor == 120499)
        #expect(stored.merchant == "AT&T*WIRELESS PMT")
        #expect(stored.cardSuffix == "7224")
        #expect(stored.currencyCode == "USD")
        #expect(stored.formattedAmount == "$1,204.99")
        #expect(stored.possibleDuplicate == false)
    }

    /// Every foreground re-runs the drain, so repeating it must change nothing.
    @Test func drainIsIdempotent() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "A"), to: url)
        try appendAlert(charge("31.79", "B"), to: url)

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
        let result = ledger.drain()
        #expect(result.eventsAdded == 0)
        #expect(result.saveError == nil)
    }

    // MARK: - What must NOT reach the ledger

    @Test func unreadableBodyKeepsTheEventButDerivesNoTransaction() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("Your Uber code is 1234", to: url)

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
        try appendAlert(
            "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4." + trailer,
            to: url
        )

        let result = ledger.drain()

        // It parses, but it is not a charge, so it must not reach the ledger. That invariant —
        // "Txn contains only charges" — is what lets the feed query need no predicate, and a
        // forgotten predicate is how an unparsed row would silently pollute a total.
        #expect(result.needsReview == 1)
        #expect(result.transactionsAdded == 0)
        #expect(txns(container).isEmpty)
    }

    /// The intent journals a rejected empty invocation with a note rather than dropping it.
    /// That record must not become an event.
    @Test func emptyBodiesAreSkippedEntirely() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("", to: url)
        try appendAlert("   ", to: url)

        let result = ledger.drain()

        #expect(result.eventsAdded == 0)
        #expect(events(container).isEmpty)
    }

    // MARK: - Replay

    /// "The raw text is kept so a parser fix can recover these" is only true if something
    /// actually re-reads it. The occurrence guard skips any event already recorded, so
    /// without the version check a failed parse would stay failed forever.
    @Test func anEventLeftByAnOlderParserIsReDerived() throws {
        let (ledger, container, _) = try makeStore()   // no journal on purpose: see below
        let body = charge("2.50", "BREEZE*00HS5MV")

        // Stand in for an event the previous parser could not read.
        let stale = AlertEvent(
            receivedAt: Date(),
            runID: UUID(),
            matchIndex: 0,
            body: body,
            contentHash: LedgerStore.contentHash(body),
            parseState: .needsReview,
            parserVersion: AlertParsers.version - 1
        )
        container.mainContext.insert(stale)
        try container.mainContext.save()
        #expect(txns(container).isEmpty)

        // No journal at all — reprocessing must not depend on one.
        let result = ledger.drain()

        #expect(result.repaired == 1)
        #expect(txns(container).count == 1)
        #expect(events(container).first?.parserVersion == AlertParsers.version)
        #expect(events(container).first?.parseState == .parsed)
    }

    @Test func anEventAlreadyCurrentIsNotReprocessed() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("Your Uber code is 1234", to: url)
        ledger.drain()

        // Current version, still unparseable — reprocessing must not spin on it forever.
        let result = ledger.drain()
        #expect(result.repaired == 0)
        #expect(txns(container).isEmpty)
    }

    // MARK: - Duplicates

    @Test func aNearIdenticalChargeIsFlaggedButNeverMerged() throws {
        let (ledger, container, url) = try makeStore()
        // Two separate invocations describing the same card, amount and merchant moments
        // apart. Both are kept; one is labelled.
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        try appendAlert("Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV.", to: url)

        ledger.drain()

        let stored = txns(container)
        #expect(stored.count == 2, "two real charges must never be silently merged into one")
        #expect(stored.filter(\.possibleDuplicate).count == 1, "exactly one should be flagged")
    }

    @Test func distinctChargesAreNotFlagged() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        try appendAlert(charge("5.30", "DEEPSEERWEA"), to: url)
        try appendAlert(charge("2.50", "SOME OTHER MERCHANT"), to: url)

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

    // MARK: - Manual entry

    /// A hand-added message must take the identical path, or the fallback would be a second
    /// ingest implementation that drifts from the real one.
    @Test func manualEntryGoesThroughTheSamePipeline() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManualEntry(charge("2.50", "BREEZE*00HS5MV"))

        let result = ledger.drain()

        #expect(result.eventsAdded == 1)
        #expect(result.transactionsAdded == 1)
        #expect(txns(container).count == 1)
        // Recorded in the journal, so it is durable and replayable like anything else.
        #expect(JournalStore.readAll(from: url).first?.note == JournalRecord.manualMarker)
    }

    @Test func emptyManualEntryIsRejected() throws {
        let (ledger, container, _) = try makeStore()
        #expect(throws: LedgerStore.ManualEntryError.self) {
            try ledger.appendManualEntry("   \n  ")
        }
        #expect(events(container).isEmpty)
    }

    /// The freshness check exists to detect the automation having stopped. A row typed by hand
    /// must not make it look alive — that would defeat the only warning the 7-day signing
    /// expiry gives.
    @Test func manualEntriesDoNotCountAsCapture() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "REAL CAPTURE"), to: url)
        let capturedAt = try #require(JournalStore.readAll(from: url).last?.receivedAt)

        // More recent than the real capture, and must still not win.
        try ledger.appendManualEntry(charge("9.99", "TYPED BY HAND"))

        let diag = ledger.diagnostics()
        #expect(diag.lastCapture == capturedAt)
        #expect(diag.lastManualEntry != nil)
    }

    @Test func diagnosticsCountWhatActuallyHappened() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "A"), to: url)
        try appendAlert("Your Uber code is 1234", to: url)

        ledger.drain()
        let diag = ledger.diagnostics()

        #expect(diag.eventCount == 2)
        #expect(diag.transactionCount == 1)
        #expect(diag.needsReviewCount == 1)
        #expect(diag.parserVersion == AlertParsers.version)
        #expect(diag.journalLines == 4)
        #expect(diag.journalBytes > 0)
    }
}
