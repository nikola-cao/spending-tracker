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
    ///
    /// `at` places the alert at a chosen arrival time, which is what the feed sorts on — the
    /// record is built directly rather than via the `.diagnostic` convenience, which always
    /// stamps `Date()`.
    private func appendAlert(
        _ body: String,
        runID: UUID = UUID(),
        at receivedAt: Date = Date(),
        to url: URL
    ) throws {
        for phase in ["enter", "result"] {
            let record = JournalRecord(
                id: UUID(),
                runID: runID,
                phase: phase,
                receivedAt: receivedAt,
                processName: "spending-tracker",
                bundleIdentifier: "com.nikola.spending-tracker",
                isMainThread: false,
                charCount: body.count,
                utf8ByteCount: body.utf8.count,
                hasFidelityPrefix: body.hasPrefix("Fidelity"),
                containsRegisteredTrademark: body.contains("\u{00AE}"),
                mentionsFidelity: FidelityAlertHeuristic.mentionsFidelity(body),
                appGroupAvailable: false,
                journalDirectory: url.deletingLastPathComponent().path,
                rawText: body,
                note: phase == "result" ? "ok" : ""
            )
            try JournalStore.append(record, to: url)
        }
    }

    /// An Amex alert as `HTMLText` would render it. The date is the same in both ordering
    /// tests on purpose — the whole point is that the message carries no time.
    private func amexAlert(_ merchant: String, _ amount: String) -> String {
        """
        See the details about this purchase
        Account Ending: 21006
        There was a large purchase on your Card
        As you requested, we're letting you know that this purchase was more than $1.00.
        \(merchant)
        $\(amount)*
        Tue, Sep 22, 2026
        """
    }

    /// A merchant's own booking confirmation, which the Email automation also captures
    /// alongside the Amex alert for the same purchase. Trimmed from a real one.
    private var merchantReceipt: String {
        """
        You're all set for Gatlinburg
        Charm of Gatlinburg Mountain Retreat condo
        Price breakdown
        $172.00 x 3 nights
        Total (USD)
        $515.66
        Payment
        Amex 1008
        September 22, 2026, 8:39:03 PM EDT
        """
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

    // MARK: - What is recorded nowhere
    //
    // Note the scope: a body that resolves to no charge is recorded NOWHERE, and the drain
    // also removes it from the journal. That was a deliberate choice over keeping unreadable
    // bodies for review, and its cost is real — a genuine charge that stops parsing now
    // disappears without a trace rather than showing up as unreadable. See the README.

    @Test func aBodyWithNoChargeIsRecordedNowhere() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("Your Uber code is 1234", to: url)

        let result = ledger.drain()

        #expect(result.notCharges == 1)
        #expect(result.eventsAdded == 0)
        #expect(result.transactionsAdded == 0)
        #expect(events(container).isEmpty)
        #expect(txns(container).isEmpty)
    }

    @Test func aNonChargeVerbIsRecordedNowhere() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(
            "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4." + trailer,
            to: url
        )

        let result = ledger.drain()

        #expect(result.notCharges == 1)
        #expect(result.transactionsAdded == 0)
        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
    }

    /// A merchant confirmation — the exact shape the Email automation captures for the very
    /// purchases Amex also alerts on. It carries the right amount and a date, and is still
    /// recorded nowhere.
    @Test func aMerchantReceiptIsRecordedNowhere() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(merchantReceipt, to: url)

        let result = ledger.drain()

        #expect(result.notCharges == 1)
        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
    }

    /// The intent journals a rejected empty invocation with a note rather than dropping it.
    /// That record must not become an event, and must not survive compaction either.
    @Test func emptyBodiesAreSkippedEntirely() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("", to: url)
        try appendAlert("   ", to: url)

        let result = ledger.drain()

        #expect(result.eventsAdded == 0)
        #expect(events(container).isEmpty)
        #expect(JournalStore.readAll(from: url).isEmpty)
    }

    // MARK: - Journal compaction
    //
    // Nothing but charges is kept, so the journal is rewritten to match. The journal is the
    // one thing in this app that must never lose data, so the properties worth pinning are
    // that it happens at all, and that it never runs when a write failed.

    @Test func theJournalDropsBodiesThatAreNotCharges() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)   // 2 lines, kept
        try appendAlert("Your Uber code is 1234", to: url)           // 2 lines, dropped

        #expect(JournalStore.readAll(from: url).count == 4)

        let result = ledger.drain()

        #expect(result.journalLinesDropped == 2)
        let kept = JournalStore.readAll(from: url)
        #expect(kept.count == 2)
        #expect(kept.allSatisfy { $0.rawText.contains("BREEZE") })
    }

    @Test func compactionLeavesOnlyCharges() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        try appendAlert(amexAlert("PUBLIX", "14.20"), to: url)
        try appendAlert(merchantReceipt, to: url)

        ledger.drain()

        let kept = JournalStore.readAll(from: url)
        #expect(kept.count == 4)   // two charges, an enter/result pair each
        for record in kept {
            #expect(AlertParsers.parseFirst(record.rawText)?.isCharge == true)
        }
    }

    /// Compaction is destructive, so a journal that is already all-charges is left byte-for-byte
    /// alone rather than rewritten on every foreground.
    @Test func anAllChargeJournalIsNotRewritten() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        let before = try Data(contentsOf: url)

        let result = ledger.drain()

        #expect(result.journalLinesDropped == 0)
        #expect(try Data(contentsOf: url) == before)
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

    // MARK: - Feed order
    //
    // The feed is a log of what ARRIVED, so it sorts on arrival. Sorting on transaction time
    // failed two ways at once, both visible on the user's own phone: every Amex row on a given
    // day shares one parsed date, so same-day Amex rows had identical sort keys and new ones
    // landed *underneath* older ones; and because Fidelity rows carry real arrival
    // timestamps, they all floated above every Amex row regardless of what came in first.

    @Test func sameDayAmexChargesStayDistinguishable() throws {
        let (ledger, container, url) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_780_000_000)

        try appendAlert(amexAlert("PUBLIX", "14.20"), at: base, to: url)
        try appendAlert(amexAlert("CINEMAPLUS", "23.85"), at: base.addingTimeInterval(1200), to: url)

        ledger.drain()
        let stored = txns(container)
        #expect(stored.count == 2)

        // Both messages print the same date and no time, so their transaction times are
        // identical and cannot order anything...
        #expect(stored[0].occurredAt == stored[1].occurredAt)

        // ...arrival can, and does.
        let byArrival = stored.sorted { $0.receivedAt > $1.receivedAt }
        #expect(byArrival.first?.merchant == "CINEMAPLUS")
        #expect(byArrival.last?.merchant == "PUBLIX")
    }

    @Test func aLaterArrivalSortsAboveRegardlessOfSource() throws {
        let (ledger, container, url) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_780_000_000)

        try appendAlert(amexAlert("PUBLIX", "14.20"), at: base, to: url)
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), at: base.addingTimeInterval(60), to: url)

        ledger.drain()
        let byArrival = txns(container).sorted { $0.receivedAt > $1.receivedAt }

        #expect(byArrival.count == 2)
        #expect(byArrival.first?.merchant == "BREEZE*00HS5MV")
        #expect(byArrival.last?.merchant == "PUBLIX")
    }

    @Test func everyRowRecordsItsArrival() throws {
        let (ledger, container, url) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_780_000_000)
        try appendAlert(amexAlert("PUBLIX", "14.20"), at: base, to: url)
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), at: base, to: url)

        ledger.drain()

        // Arrival is the sort key, so it can never be absent — for either source.
        for txn in txns(container) {
            #expect(txn.receivedAt == base)
        }
        // Only the source that prints a date gets one.
        #expect(txns(container).filter(\.occurredAtIsFromMessage).count == 1)
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

        // One charge recorded; the unreadable body is nowhere, including in the journal count.
        #expect(diag.eventCount == 1)
        #expect(diag.transactionCount == 1)
        #expect(diag.parserVersion == AlertParsers.version)
        #expect(diag.journalLines == 2)
        #expect(diag.journalBytes > 0)
    }
}
