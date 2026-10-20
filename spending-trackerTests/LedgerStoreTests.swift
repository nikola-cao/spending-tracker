//
//  LedgerStoreTests.swift
//  spending-trackerTests
//

import Foundation
import SwiftData
import Testing
@testable import spending_tracker

/// Serialized, unlike the rest of the suite. One test below writes the pre-journal balance key
/// in `UserDefaults`, which is process-wide state that `refreshBankBalance` reads on every
/// drain — so a parallel test draining an empty journal would adopt it and append a `Bank`
/// line to a journal it does not own, which is a flake in whichever test happens to lose the
/// race. `BankBalance` has no injection point, deliberately: the value is a one-time handover
/// from an older version and there is nothing to inject.
@MainActor
@Suite(.serialized)
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

    /// Writes one alert exactly as `LogTransactionIntent` does: **a single line**, with the
    /// runID the ledger dedupes on supplied by the caller so tests control it.
    ///
    /// `at` places the alert at a chosen arrival time, which is what the feed sorts on. The
    /// record is built directly rather than via the `.diagnostic` convenience, which always
    /// stamps `Date()`.
    ///
    /// `note` defaults to empty because that is what a captured alert carries — the intent writes
    /// an empty note. **A line the app wrote to itself must say so**: the drain reads instructions
    /// only from lines stamped `manualMarker`, because a body a source sent is evidence and never
    /// a command. A fixture that writes a `Bank |` or `Category |` line without the marker is
    /// describing something no version of this app has ever produced.
    private func appendAlert(
        _ body: String,
        runID: UUID = UUID(),
        at receivedAt: Date = Date(),
        note: String = "",
        to url: URL
    ) throws {
        try appendRecord(
            body, runID: runID, phase: JournalRecord.capturePhase, at: receivedAt, note: note, to: url)
    }

    /// Writes an alert the way versions before single-line capture did: an `enter`/`result`
    /// pair sharing one runID. Kept because journals in the field still contain pairs, and the
    /// drain has to keep collapsing them.
    private func appendLegacyPair(
        _ body: String,
        runID: UUID = UUID(),
        at receivedAt: Date = Date(),
        to url: URL
    ) throws {
        try appendRecord(body, runID: runID, phase: "enter", at: receivedAt, to: url)
        try appendRecord(body, runID: runID, phase: "result", at: receivedAt, to: url)
    }

    private func appendRecord(
        _ body: String,
        runID: UUID,
        phase: String,
        at receivedAt: Date,
        note: String = "",
        to url: URL
    ) throws {
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
            note: note
        )
        try JournalStore.append(record, to: url)
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

    /// A current journal is one line per alert, so the ledger sees exactly one record.
    @Test func oneAlertIsOneJournalLine() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)

        let result = ledger.drain()

        #expect(result.recordsRead == 1)
        #expect(result.eventsAdded == 1)
        #expect(txns(container).count == 1)
    }

    /// Journals written before single-line capture hold an `enter`/`result` pair per alert, and
    /// those still have to collapse to one row rather than two.
    @Test func aLegacyEnterResultPairCollapsesToOneRow() throws {
        let (ledger, container, url) = try makeStore()
        try appendLegacyPair(charge("2.50", "BREEZE*00HS5MV"), to: url)

        let result = ledger.drain()

        #expect(result.recordsRead == 2, "the legacy pair is two journal lines")
        #expect(result.eventsAdded == 1, "but one alert")
        #expect(result.transactionsAdded == 1)
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
    /// That record must not become an event.
    @Test func emptyBodiesBecomeNoEvent() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert("", to: url)
        try appendAlert("   ", to: url)

        let result = ledger.drain()

        #expect(result.eventsAdded == 0)
        #expect(events(container).isEmpty)
    }

    // MARK: - Journal retention
    //
    // Charges are kept forever; anything else is held for a week and then purged. The journal
    // is the one thing in this app that must never lose data, so the properties worth pinning
    // are that the window is respected in BOTH directions, and that nothing is dropped when a
    // write failed.

    @Test func aRecentNonChargeIsKept() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        try appendAlert("Your Uber code is 1234", to: url)     // not a charge, but recent

        let result = ledger.drain()

        // Nothing is discarded on arrival — the body stays recoverable for a week.
        #expect(result.journalLinesDropped == 0)
        #expect(JournalStore.readAll(from: url).count == 2)
        // ...and it still never becomes a ledger row.
        #expect(result.notCharges == 1)
        #expect(txns(container).count == 1)
    }

    @Test func aNonChargeOlderThanAWeekIsPurged() throws {
        let (ledger, container, url) = try makeStore()
        let eightDaysAgo = Date().addingTimeInterval(-8 * 24 * 60 * 60)

        try appendAlert(merchantReceipt, at: eightDaysAgo, to: url)            // evicted
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), at: Date(), to: url)

        let result = ledger.drain()

        #expect(result.journalLinesDropped == 1)
        let kept = JournalStore.readAll(from: url)
        #expect(kept.count == 1)
        #expect(kept.allSatisfy { $0.rawText.contains("BREEZE") })
        #expect(txns(container).count == 1)
    }

    /// The window must never touch a charge, however old.
    @Test func chargesAreKeptHoweverOld() throws {
        let (ledger, container, url) = try makeStore()
        let longAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), at: longAgo, to: url)

        let result = ledger.drain()

        #expect(result.journalLinesDropped == 0)
        #expect(JournalStore.readAll(from: url).count == 1)
        #expect(txns(container).count == 1)
    }

    /// A journal with nothing to purge is left byte-for-byte alone rather than rewritten on
    /// every foreground.
    @Test func aJournalWithNothingToPurgeIsNotRewritten() throws {
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

    // MARK: - Deleting
    //
    // Deleting a charge has to remove its journal line too. The store is derived, so a row
    // deleted from the store ALONE is recreated by the very next drain — which is why that is
    // the property worth testing, not just the deletion itself.

    @Test func deletingAChargeRemovesItEverywhere() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()
        #expect(txns(container).count == 1)

        let removed = try ledger.delete(txns(container))

        #expect(removed.rows == 1)
        #expect(removed.lines == 1)
        #expect(removed.saveError == nil)
        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
        #expect(JournalStore.readAll(from: url).isEmpty)
    }

    /// The one that matters. Without the journal edit this drain recreates the row, and the
    /// deletion looks like it silently undid itself.
    @Test func aDeletedChargeDoesNotComeBackOnTheNextDrain() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()

        try ledger.delete(txns(container))
        ledger.drain()

        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
    }

    @Test func deletingOneChargeLeavesTheOthersAlone() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "KEEP ME"), to: url)
        try appendAlert(charge("9.99", "DELETE ME"), to: url)
        ledger.drain()
        #expect(txns(container).count == 2)

        let doomed = try #require(txns(container).first { $0.merchant == "DELETE ME" })
        try ledger.delete([doomed])

        let left = txns(container)
        #expect(left.count == 1)
        #expect(left.first?.merchant == "KEEP ME")

        // Only the dead one left the journal.
        let journal = JournalStore.readAll(from: url)
        #expect(journal.contains { $0.rawText.contains("KEEP ME") })
        #expect(!journal.contains { $0.rawText.contains("DELETE ME") })
    }

    /// A deleted charge must not be resurrected by a later drain either — including one
    /// triggered by an unrelated new alert.
    @Test func aDeletedChargeStaysDeletedWhenAnotherArrives() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "DELETE ME"), to: url)
        ledger.drain()
        try ledger.delete(txns(container))

        try appendAlert(charge("9.99", "LATER"), to: url)
        ledger.drain()

        let left = txns(container)
        #expect(left.count == 1)
        #expect(left.first?.merchant == "LATER")
    }

    @Test func deletingNothingIsHarmless() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()

        #expect(try ledger.delete([]).rows == 0)
        #expect(txns(container).count == 1)
    }

    // MARK: - Deleting from the journal
    //
    // The other direction of the same operation: the Raw journal screen picks a LINE, where the
    // feed picks a row. Deleting from a line is the only way to remove a body that resolved to
    // no charge — a merchant's own confirmation, an OTP, a statement notice — because those
    // have no row to swipe.

    /// Writes a body that resolves to no ledger entry, exactly as the Email automation does.
    private func appendJunk(_ body: String, to url: URL) throws {
        try appendAlert(body, to: url)
    }

    /// The line the Raw journal screen would hand back: the newest one, by file order.
    private func newestRecord(in url: URL) throws -> JournalRecord {
        try #require(JournalStore.readAll(from: url).last)
    }

    @Test func deletingAJournalLineRemovesTheTransactionItRecorded() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()

        let result = try ledger.deleteJournalLine(try newestRecord(in: url))

        #expect(result.lines == 1)
        #expect(result.rows == 1, "the row the line produced goes with it")
        #expect(result.saveError == nil)
        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
        #expect(JournalStore.readAll(from: url).isEmpty)
    }

    /// The case the feature exists for. A body that resolved to nothing has no row, so the
    /// feed's swipe-to-delete could never reach it.
    @Test func aJournalLineThatRecordedNothingCanStillBeDeleted() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "KEEP ME"), to: url)
        try appendJunk(merchantReceipt, to: url)
        ledger.drain()
        #expect(events(container).count == 1, "the receipt resolves to no charge")

        let result = try ledger.deleteJournalLine(try newestRecord(in: url))

        #expect(result.lines == 1)
        #expect(result.rows == 0, "there is no row to remove, and the copy must not claim one")
        let left = JournalStore.readAll(from: url)
        #expect(left.count == 1)
        #expect(left.first?.rawText.contains("KEEP ME") == true)
        #expect(txns(container).count == 1, "the other invocation is untouched")
    }

    /// A journal written before single-line capture holds an `enter`/`result` pair under one
    /// runID. Deleting either line has to take both: the surviving twin would rebuild the row
    /// on the very next drain, which is the whole failure the journal edit exists to prevent.
    @Test func deletingOneLineOfALegacyPairRemovesBoth() throws {
        let (ledger, container, url) = try makeStore()
        try appendLegacyPair(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()
        #expect(JournalStore.readAll(from: url).count == 2)

        let result = try ledger.deleteJournalLine(try #require(JournalStore.readAll(from: url).first))
        ledger.drain()

        #expect(result.lines == 2, "both halves of the invocation go")
        #expect(JournalStore.readAll(from: url).isEmpty)
        #expect(txns(container).isEmpty, "and the twin must not bring it back")
    }

    /// One message can carry two alerts. The line is the invocation's, so deleting it removes
    /// both rows — there is no way to remove one and keep the other, because the journal line
    /// they share is the evidence for both.
    @Test func deletingABodyWithTwoAlertsRemovesBothTransactions() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("36.00", "Georgia Tech Parking S") + charge("73.00", "CENTRAL ROCK MID (ATL)")
        try appendAlert(body, to: url)
        ledger.drain()
        #expect(txns(container).count == 2)

        let result = try ledger.deleteJournalLine(try newestRecord(in: url))

        #expect(result.rows == 2)
        #expect(txns(container).isEmpty)
        #expect(events(container).isEmpty)
    }

    /// The same change seen from the feed, which is where it is a behaviour change: swiping one
    /// row of a two-alert message now takes the sibling too. Before, the sibling stayed in the
    /// store with its journal line gone — a row a rebuild would drop with no explanation.
    @Test func theFeedSwipeRemovesEveryRowOfTheInvocation() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("36.00", "Georgia Tech Parking S") + charge("73.00", "CENTRAL ROCK MID (ATL)")
        try appendAlert(body, to: url)
        ledger.drain()

        let one = try #require(txns(container).first)
        let result = try ledger.delete([one])

        #expect(result.rows == 2, "one swipe, one invocation, both rows")
        #expect(txns(container).isEmpty)
        #expect(JournalStore.readAll(from: url).isEmpty)
    }

    @Test func deletingAJournalLineLeavesOtherInvocationsAlone() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "KEEP ME"), to: url)
        try appendAlert(charge("9.99", "DELETE ME"), to: url)
        ledger.drain()

        let doomed = try #require(
            JournalStore.readAll(from: url).first { $0.rawText.contains("DELETE ME") })
        try ledger.deleteJournalLine(doomed)
        ledger.drain()

        let left = txns(container)
        #expect(left.count == 1)
        #expect(left.first?.merchant == "KEEP ME")
    }

    /// Deleting from the journal must be as permanent as deleting from the feed. Without the
    /// line going too, this drain rebuilds the row and the delete looks like it undid itself.
    @Test func aDeletedJournalLineDoesNotComeBackOnTheNextDrain() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "DELETE ME"), to: url)
        ledger.drain()
        try ledger.deleteJournalLine(try newestRecord(in: url))

        try appendAlert(charge("9.99", "LATER"), to: url)
        ledger.drain()

        let left = txns(container)
        #expect(left.count == 1)
        #expect(left.first?.merchant == "LATER")
    }

    /// Deleting a deposit's line gives the money back with no separate bookkeeping — the fold
    /// simply sees one fewer line. This is the reason the balance is derived at all.
    @Test func deletingADepositLineFromTheJournalGivesTheMoneyBack() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(10_000)
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_500)

        let result = try ledger.deleteJournalLine(try newestRecord(in: url))
        ledger.drain()

        #expect(result.rows == 1)
        #expect(ledger.bankBalanceMinor == 10_000)
        #expect(txns(container).isEmpty)
    }

    /// An instruction line is deletable like anything else, and its consequence is visible:
    /// dropping the balance assertion restates the Bank figure from what is left, rather than
    /// leaving the number it was asserting.
    @Test func deletingABalanceLineRestatesTheBankFromWhatIsLeft() throws {
        let (ledger, _, url) = try makeStore()
        try ledger.setBankBalance(10_000)
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_500)

        let balanceLine = try #require(JournalStore.readAll(from: url).first)
        #expect(balanceLine.outcome == .instruction(.setBankBalance(minor: 10_000)))

        let result = try ledger.deleteJournalLine(balanceLine)
        ledger.drain()

        #expect(result.rows == 0, "an instruction is not a row")
        #expect(ledger.bankBalanceMinor == 2_500, "only the deposit is left to fold")
    }

    /// And an edit is deletable, which is the only way to undo one from the journal side: the
    /// row goes back to what the line this edit superseded said.
    @Test func deletingAnEditLineRevertsTheRowItChanged() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        try ledger.edit(
            try #require(txns(container).first),
            merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "7224")
        ledger.drain()
        #expect(txns(container).first?.merchant == "BREEZE COFFEE")

        let result = try ledger.deleteJournalLine(try newestRecord(in: url))
        ledger.drain()

        // The row the edit named goes with the line, so the drain re-derives it from the
        // original. Counting it is right: it is the row that changes.
        #expect(result.rows == 1)
        let row = try #require(txns(container).first)
        #expect(row.merchant == "BREEZE", "the original line is still there, and now unedited")
        #expect(row.amountMinor == 250)
    }

    /// Deleting an edit line writes the **store** first — the opposite of every other deletion —
    /// and this is why. Here the journal write is made to fail after the row has already gone,
    /// which in the other order would leave the store holding the edited values with no edit
    /// left to explain them, permanently. The surviving edit line rebuilds the row instead.
    @Test func aFailedEditDeletionRebuildsTheRowFromTheSurvivingLine() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()
        try ledger.edit(
            try #require(txns(container).first),
            merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "7224")
        ledger.drain()
        #expect(txns(container).first?.merchant == "BREEZE COFFEE")

        let editLine = try newestRecord(in: url)
        let saved = try Data(contentsOf: url)

        // Present and unreadable as a file, so the store half lands and the journal half throws.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(throws: JournalStoreError.self) {
            try ledger.deleteJournalLine(editLine)
        }
        #expect(txns(container).isEmpty, "the store half did land — the row was re-derivable, not removed")

        // The journal comes back, and with it the row: the edit line survived, so the drain
        // re-ingests the original and replays the edit onto it.
        try FileManager.default.removeItem(at: url)
        try saved.write(to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.merchant == "BREEZE COFFEE", "the surviving line rebuilds the row as it was")
        #expect(row.amountMinor == 400)
    }

    /// Deleting the newest of two edits must not throw the older one away: the row is re-derived
    /// and then every edit still standing is replayed onto it, in journal order.
    @Test func deletingOneEditLeavesTheEarlierOnesStanding() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        try ledger.edit(
            try #require(txns(container).first),
            merchant: "FIRST EDIT", amount: "3.00", date: nil, cardSuffix: "7224")
        ledger.drain()
        try ledger.edit(
            try #require(txns(container).first),
            merchant: "SECOND EDIT", amount: "4.00", date: nil, cardSuffix: "7224")
        ledger.drain()
        #expect(txns(container).first?.merchant == "SECOND EDIT")

        try ledger.deleteJournalLine(try newestRecord(in: url))
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.merchant == "FIRST EDIT", "the surviving edit is replayed onto the re-derived row")
        #expect(row.amountMinor == 300)
    }

    /// The regression that made the atomic rewrite necessary. A journal that is present and
    /// unreadable must not be treated as empty: the rows would be deleted, the lines would
    /// survive, and the next drain would bring every row back.
    @Test func aJournalThatCannotBeReadDeletesNothing() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()
        let record = try newestRecord(in: url)

        // Present, and unreadable as a file: a directory where the journal should be.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(throws: JournalStoreError.self) {
            try ledger.deleteJournalLine(record)
        }
        #expect(txns(container).count == 1, "the row must survive a journal that could not be read")
        #expect(events(container).count == 1)
    }

    /// The count the confirmation is built from has to come from the store, not from re-parsing
    /// the text — the two can disagree, and the copy is the thing the user trusts before
    /// destroying the only copy of the evidence.
    @Test func rowsRecordedCountsWhatTheStoreHolds() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        try appendJunk("Your Uber code is 1234", to: url)
        ledger.drain()

        let stored = JournalStore.readAll(from: url)
        let chargeLine = try #require(stored.first { $0.rawText.contains("BREEZE") })
        let junkLine = try #require(stored.first { $0.rawText.contains("Uber") })

        #expect(ledger.rowsRecorded(by: chargeLine) == 1)
        #expect(ledger.rowsRecorded(by: junkLine) == 0)
    }

    // MARK: - The raw line behind one row

    /// The transaction detail's lookup. The row's event names the invocation and the journal is
    /// keyed on exactly that — this is the property the whole feature rests on.
    @Test func journalLinkNamesTheLineTheRowWasRecordedFrom() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("2.50", "BREEZE*00HS5MV")
        try appendAlert(body, to: url)
        try appendAlert(charge("9.99", "ELSEWHERE"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first { $0.merchant == "BREEZE*00HS5MV" })
        guard case .lines(let lines) = ledger.journalLink(for: row) else {
            Issue.record("expected the capture line, saw \(ledger.journalLink(for: row))")
            return
        }

        #expect(lines.count == 1)
        #expect(lines.first?.rawText == body)
    }

    /// A journal written before single-line capture holds an `enter`/`result` pair under one
    /// runID. Both halves are the evidence for the row, and both are returned in file order.
    @Test func journalLinkForALegacyPairReturnsBothLines() throws {
        let (ledger, container, url) = try makeStore()
        try appendLegacyPair(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        guard case .lines(let lines) = ledger.journalLink(for: row) else {
            Issue.record("expected both halves of the pair")
            return
        }

        #expect(lines.map(\.phase) == ["enter", "result"])
    }

    /// An edit and a category are instructions *about* the row, not the body it was recorded
    /// from. The detail shows the capture line; the instructions stay on the Raw journal screen.
    @Test func journalLinkIgnoresInstructionsAboutTheRow() throws {
        let (ledger, container, url) = try makeStore()
        let body = charge("2.50", "BREEZE")
        try appendAlert(body, to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try ledger.edit(
            row, merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "7224")
        try ledger.setCategory(row, label: "dining")
        try ledger.setMerchantRule(merchant: "BREEZE COFFEE", label: "dining")
        ledger.drain()

        guard case .lines(let lines) = ledger.journalLink(for: row) else {
            Issue.record("expected the capture line only")
            return
        }

        #expect(lines.count == 1, "instructions name the row; they are not its evidence")
        #expect(lines.first?.rawText == body)
    }

    /// The state a deletion whose store half failed leaves: the line is gone and the row is
    /// still in the store. It is `.missing`, not `.noEvent` and not an empty list, because the
    /// form has to know it cannot write an instruction against this row.
    @Test func journalLinkWhenTheLineIsGoneButTheRowRemains() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let runID = try #require(txns(container).first?.event?.runID)
        try JournalStore.remove(from: url) { $0.runID == runID }

        let row = try #require(txns(container).first)
        #expect(ledger.journalLink(for: row) == .missing)
    }

    /// A row with no event has no line and never can. Distinct from `.missing`, which says the
    /// journal lost a line it used to hold.
    @Test func journalLinkForARowWithNoEvent() throws {
        let (ledger, _, _) = try makeStore()
        let orphan = Txn(
            amountMinor: 100, currencyCode: "USD", cardSuffix: "", merchant: "ORPHAN",
            receivedAt: Date(), occurredAt: Date(), occurredAtIsFromMessage: false,
            parserVersion: 1)

        #expect(ledger.journalLink(for: orphan) == .noEvent)
    }

    /// A journal that is there and cannot be read must not be reported as "no line". The row
    /// still exists; the file is what failed — the Raw journal screen's rule, one level up.
    @Test func journalLinkWhenTheJournalCannotBeRead() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()
        let row = try #require(txns(container).first)

        // Present, and unreadable as a file: a directory where the journal should be.
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        #expect(ledger.journalLink(for: row) == .unreadable)
    }

    /// Deleting an invocation takes the edit and category lines that name it. Instruction lines
    /// are kept forever by the retention purge, so a surviving one would point at a row no
    /// rebuild can produce — permanently. A merchant rule is about a merchant, not this row,
    /// and stays.
    @Test func deletingAnInvocationTakesItsInstructionsWithIt() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        let runID = try #require(row.event?.runID)
        try ledger.edit(row, merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "")
        try ledger.setCategory(row, label: "dining")
        try ledger.setMerchantRule(merchant: "BREEZE", label: "dining")
        ledger.drain()
        #expect(JournalStore.readAll(from: url).count == 4)

        let result = try ledger.deleteJournalInvocation(runID: runID)

        #expect(result.lines == 3, "the capture line and the two instructions that named it")
        #expect(result.rows == 1)
        #expect(result.saveError == nil)
        #expect(txns(container).isEmpty)

        let left = JournalStore.readAll(from: url)
        #expect(left.count == 1)
        #expect(left.first?.trimmedBody.hasPrefix(
            JournalInstructionParser.merchantCategoryPrefix) == true,
                "a rule about the merchant outlives the row it happened to match")
    }

    /// A pre-journal balance in `UserDefaults` is adopted only when the fold derives nothing.
    /// That branch is skipped on any device whose journal already derives a balance — so the
    /// stale value was never cleared, and deleting the last line that derived one would adopt
    /// it and write a balance nobody set into the journal.
    @Test func deletingTheLastDepositDoesNotResurrectAPreJournalBalance() throws {
        let (ledger, _, url) = try makeStore()
        UserDefaults.standard.set(50_000, forKey: BankBalance.legacyDefaultsKey)
        defer { BankBalance.clearLegacyStoredValue() }

        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 2_500)

        try ledger.deleteJournalLine(try newestRecord(in: url))
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 0)
        #expect(JournalStore.readAll(from: url).isEmpty,
                "the drain may not fabricate a Bank line from a value this version never had")
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

    // MARK: - Manual charges from the form

    @Test func aManualChargeTakesTheSamePipeline() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManual(
            kind: .charge,
            merchant: "HAND TYPED", amount: "12.34", date: Date(), cardSuffix: "7224")

        let result = ledger.drain()

        #expect(result.transactionsAdded == 1)
        let stored = try #require(txns(container).first)
        #expect(stored.merchant == "HAND TYPED")
        #expect(stored.amountMinor == 1234)
        #expect(stored.cardSuffix == "7224")

        // Written to the journal like anything else, which is what makes it survive a rebuild,
        // fall under the retention window, and be deletable — none of which a row written
        // straight into the store would do.
        let journal = try #require(JournalStore.readAll(from: url).first)
        #expect(journal.rawText.hasPrefix("Manual | "))
    }

    @Test func aManualChargeCanBeDeletedLikeAnyOther() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManual(
            kind: .charge,
            merchant: "HAND TYPED", amount: "12.34", date: Date(), cardSuffix: "7224")
        ledger.drain()
        #expect(txns(container).count == 1)

        try ledger.delete(txns(container))
        ledger.drain()

        #expect(txns(container).isEmpty)
        #expect(JournalStore.readAll(from: url).isEmpty)
    }

    @Test func aManualChargeCanBeReadBackAfterARebuild() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManual(
            kind: .charge,
            merchant: "HAND TYPED", amount: "12.34", date: Date(), cardSuffix: "7224")
        ledger.drain()
        #expect(txns(container).count == 1)

        // A fresh store reading the SAME journal is what a rebuild looks like: the journal is
        // the only thing that carries over. (`makeStore()` would hand back a different, empty
        // journal, which tests nothing.)
        let freshContainer = try ModelContainer(
            for: Schema([AlertEvent.self, Txn.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        LedgerStore(container: freshContainer, journalURL: url).drain()

        #expect(txns(freshContainer).count == 1)
        #expect(txns(freshContainer).first?.merchant == "HAND TYPED")
    }

    @Test func aManualChargeNeedsOnlyAMerchantAndAnAmount() throws {
        let (ledger, container, _) = try makeStore()
        try ledger.appendManual(
            kind: .charge,
            merchant: "NO CARD NO DATE", amount: "5.00", date: nil, cardSuffix: "")
        ledger.drain()

        let stored = try #require(txns(container).first)
        #expect(stored.merchant == "NO CARD NO DATE")
        #expect(stored.amountMinor == 500)
        #expect(stored.cardSuffix == "")
        // No date of its own, so it takes the arrival time — and the feed will label it
        // "Alerted" rather than "Purchased", which is honest about what is actually known.
        #expect(stored.occurredAtIsFromMessage == false)
    }

    @Test func knownCardsComeFromWhatWasActuallyCaptured() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "A", last4: "7224"), to: url)
        try appendAlert(amexAlert("PUBLIX", "14.20"), to: url)   // card 21006
        ledger.drain()

        // Includes a card only ever seen through an automation — that is the point of reading
        // this from the ledger rather than from the form's own history.
        #expect(Set(ledger.knownCardSuffixes()) == ["7224", "21006"])
    }

    @Test func knownCardsAreEmptyBeforeAnythingIsCaptured() throws {
        let (ledger, _, _) = try makeStore()
        #expect(ledger.knownCardSuffixes().isEmpty)
    }

    @Test func diagnosticsCountWhatActuallyHappened() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("2.50", "A"), to: url)
        try appendAlert("Your Uber code is 1234", to: url)

        ledger.drain()
        let diag = ledger.diagnostics()

        // One charge recorded. The unreadable body is no ledger row, but it IS still in the
        // journal — two lines: one for the charge, one for the body held for a week.
        #expect(diag.eventCount == 1)
        #expect(diag.transactionCount == 1)
        #expect(diag.parserVersion == AlertParsers.version)
        #expect(diag.journalLines == 2)
        #expect(diag.journalBytes > 0)
    }

    // MARK: - The bank balance
    //
    // Derived by folding the journal, never stored. The property that matters is the one the
    // user asked for: set it, throw the store away, rebuild, and it is still there.

    private func appendDeposit(_ amount: String, _ merchant: String, to url: URL) throws {
        try appendAlert(
            ManualEntryParser.compose(
                kind: .deposit, merchant: merchant, amount: amount, date: nil, cardSuffix: ""),
            to: url
        )
    }

    @Test func aBalanceSetByHandSurvivesARebuild() throws {
        let (ledger, _, url) = try makeStore()
        try ledger.setBankBalance(120_000)
        #expect(ledger.bankBalanceMinor == 120_000)

        // A second store over the same journal is exactly what `resetStoreIfSchemaChanged`
        // leaves behind: the rows are gone and the journal is all there is.
        let rebuilt = LedgerStore(
            container: try ModelContainer(
                for: Schema([AlertEvent.self, Txn.self]),
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            ),
            journalURL: url
        )
        rebuilt.drain()

        #expect(rebuilt.bankBalanceMinor == 120_000)
    }

    @Test func aDepositMovesTheBalanceAndSurvivesARebuildToo() throws {
        let (ledger, _, url) = try makeStore()
        // $100.00 in the bank, then $25.00 in.
        try ledger.setBankBalance(10_000)
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 12_500)

        let rebuilt = LedgerStore(
            container: try ModelContainer(
                for: Schema([AlertEvent.self, Txn.self]),
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            ),
            journalURL: url
        )
        rebuilt.drain()
        #expect(rebuilt.bankBalanceMinor == 12_500)
    }

    /// A balance is an assertion about the world, not a movement, so it wins outright rather
    /// than adjusting — including over the deposits that came before it.
    @Test func aBalanceSetAfterADepositOverridesIt() throws {
        let (ledger, _, url) = try makeStore()
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        try ledger.setBankBalance(100_000)

        #expect(ledger.bankBalanceMinor == 100_000)
    }

    /// Deleting the row removes its journal line, so the fold simply sees one fewer deposit.
    /// No separate bookkeeping — which is the reason the balance is derived at all.
    @Test func deletingADepositGivesTheMoneyBack() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(10_000)
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_500)

        try ledger.delete(txns(container))
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 10_000)
    }

    /// An instruction line is kept forever, exactly as a charge is. Dropping an old one would
    /// quietly restate the balance the day it aged out of the retention window.
    @Test func anOldBalanceLineIsNeverPurged() throws {
        let (ledger, _, url) = try makeStore()
        // Arrived well outside the week-long window that non-charges get.
        try appendAlert(
            JournalInstructionParser.composeBankBalance(50_000),
            at: Date().addingTimeInterval(-30 * 24 * 60 * 60),
            note: JournalRecord.manualMarker,
            to: url
        )

        ledger.drain()

        #expect(ledger.bankBalanceMinor == 50_000)
        #expect(JournalStore.readAll(from: url).count == 1)
    }

    /// The feed shows one month at a time; the bank does not. A deposit from a month the list
    /// is no longer showing is still money that moved, so the fold reads the whole journal
    /// rather than whatever is on screen.
    @Test func anEarlierMonthsDepositStillCountsTowardsTheBank() throws {
        let (ledger, _, url) = try makeStore()
        let longAgo = Date().addingTimeInterval(-90 * 24 * 60 * 60)

        try ledger.setBankBalance(10_000)
        try appendAlert(
            ManualEntryParser.compose(
                kind: .deposit, merchant: "OLD ZELLE", amount: "25.00", date: longAgo,
                cardSuffix: ""),
            at: longAgo,
            to: url
        )
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 12_500)
    }

    // MARK: - The card balance

    /// What is owed: what the cards were charged, less what has been paid off. Charges and
    /// payments are the only two kinds that move it.
    @Test func theCardBalanceIsChargesLessPayments() throws {
        let (ledger, _, url) = try makeStore()

        try appendAlert(charge("40.00", "BREEZE COFFEE"), to: url)
        try appendAlert(charge("15.49", "NETFLIX.COM"), to: url)
        try appendAlert(
            ManualEntryParser.compose(
                kind: .payment, merchant: "AMEX PAYMENT", amount: "-20.00", date: nil,
                cardSuffix: ""),
            to: url
        )
        ledger.drain()

        #expect(ledger.cardBalanceMinor == 3_549, "4000 + 1549 - 2000")
    }

    /// A deposit never touches a card, whichever way the money went.
    ///
    /// This is the one place the card fold and the bank fold part company, and the reason they
    /// are two folds rather than one. Folding deposits in would have counted every Zelle twice:
    /// once as money that moved, and once as money owed.
    @Test func aDepositLeavesTheCardBalanceAlone() throws {
        let (ledger, _, url) = try makeStore()

        try appendDeposit("300.00", "ZELLE FROM SAM", to: url)
        try appendAlert(
            ManualEntryParser.compose(
                kind: .deposit, merchant: "VENMO PAYMENT", amount: "-200.00", date: nil,
                cardSuffix: ""),
            to: url
        )
        ledger.drain()

        #expect(ledger.cardBalanceMinor == 0, "neither direction of a deposit touches a card")
        #expect(ledger.bankBalanceMinor == 10_000, "and both of them move the bank")
    }

    /// A declined alert is not a movement of money, so it must not move a balance.
    ///
    /// This is the case that decides the fold's predicate, and it is not hypothetical — the
    /// body below is in the corpus. "Anything that is not a deposit" reads as the obvious
    /// predicate to write, and it is **true** of an unrecognised verb. Folding on it would raise
    /// the card balance by an amount the feed never showed, and then drop it again a week later
    /// when the retention window purged the line it came from: a figure moving with no row
    /// changing, which is the least explicable thing this app could do.
    @Test func aDeclinedAlertLeavesTheCardBalanceAlone() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(
            "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4." + trailer,
            to: url
        )

        let result = ledger.drain()

        #expect(result.notCharges == 1)
        #expect(txns(container).isEmpty)
        #expect(ledger.cardBalanceMinor == 0, "nothing was charged, so nothing is owed")
    }

    /// An assertion about the world beats everything before it, exactly as a `Bank` line does.
    /// What comes after it still adds.
    @Test func aCardBalanceLineOverridesEverythingBeforeIt() throws {
        let (ledger, _, url) = try makeStore()

        try appendAlert(charge("40.00", "BREEZE COFFEE"), to: url)
        try appendAlert(
            JournalInstructionParser.composeCardBalance(120_000),
            note: JournalRecord.manualMarker, to: url)
        try appendAlert(charge("10.00", "LATER COFFEE"), to: url)
        ledger.drain()

        #expect(ledger.cardBalanceMinor == 121_000,
                "the line restates it; only the charge after it adds")
    }

    /// Two of them, and the last wins — the same rule, and for the same reason, as a second
    /// `Bank` line.
    @Test func theLastCardBalanceLineWins() throws {
        let (ledger, _, url) = try makeStore()

        try appendAlert(
            JournalInstructionParser.composeCardBalance(10_000),
            note: JournalRecord.manualMarker, to: url)
        try appendAlert(
            JournalInstructionParser.composeCardBalance(25_000),
            note: JournalRecord.manualMarker, to: url)
        ledger.drain()

        #expect(ledger.cardBalanceMinor == 25_000)
    }

    /// The fold re-parses every line it is handed, and a charge captured before single-line
    /// capture was journalled **twice** under one runID. Without collapsing the pair the card
    /// balance reads as double the row printed directly beneath it.
    ///
    /// The bank fold never had to care, because the only kinds it summed — deposits and
    /// payments — postdate the pair entirely. Charges are the kind that *was* paired, and
    /// charges are the kind a card balance is made of.
    @Test func aLegacyChargePairCountsOnceTowardsTheCardBalance() throws {
        let (ledger, container, url) = try makeStore()

        try appendLegacyPair(charge("2.50", "BREEZE*00HS5MV"), to: url)
        ledger.drain()

        #expect(txns(container).count == 1, "the two lines are one invocation")
        #expect(ledger.cardBalanceMinor == 250, "and one charge's worth of balance")
    }

    /// An edit has to reach the card balance, or the figure disagrees with the row printed
    /// directly beneath it — and that row is the one the user just changed.
    @Test func editingAChargeChangesWhatItDidToTheCardBalance() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("25.00", "BREEZE COFFEE"), to: url)
        ledger.drain()
        #expect(ledger.cardBalanceMinor == 2_500)

        let txn = try #require(txns(container).first)
        try ledger.edit(txn, merchant: "BREEZE COFFEE", amount: "40.00", date: nil, cardSuffix: "")
        ledger.drain()

        #expect(ledger.cardBalanceMinor == 4_000)
    }

    /// Derived, like the bank and for the same reason: a schema change deletes the store, and
    /// the journal is then the only thing that can restore the figure.
    @Test func aCardBalanceSetByHandSurvivesARebuild() throws {
        let (ledger, _, url) = try makeStore()
        try ledger.setCardBalance(88_800)
        #expect(ledger.cardBalanceMinor == 88_800)

        // A second store over the same journal is exactly what `resetStoreIfSchemaChanged`
        // leaves behind: the rows are gone and the journal is all there is.
        let rebuilt = LedgerStore(
            container: try ModelContainer(
                for: Schema([AlertEvent.self, Txn.self]),
                configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
            ),
            journalURL: url
        )
        rebuilt.drain()

        #expect(rebuilt.cardBalanceMinor == 88_800)
    }

    /// Deleting the line removes the assertion and the figure is restated from what is left —
    /// the behaviour the Raw journal's confirmation dialog promises when it offers the swipe.
    @Test func deletingACardBalanceLineRestatesFromWhatIsLeft() throws {
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("25.00", "BREEZE COFFEE"), to: url)
        try ledger.setCardBalance(50_000)
        #expect(ledger.cardBalanceMinor == 50_000)

        let cardLine = try #require(JournalStore.readAll(from: url).last)
        #expect(cardLine.outcome == .instruction(.setCardBalance(minor: 50_000)))

        let result = try ledger.deleteJournalLine(cardLine)
        ledger.drain()

        #expect(result.rows == 0, "an instruction is not a row")
        #expect(ledger.cardBalanceMinor == 2_500, "only the charge is left to fold")
    }

    /// Kept forever, like every other instruction. Dropping an old one would quietly restate
    /// the Balance the day it aged out of the retention window.
    @Test func anOldCardBalanceLineIsNeverPurged() throws {
        let (ledger, _, url) = try makeStore()
        // Arrived well outside the week-long window that non-charges get.
        try appendAlert(
            JournalInstructionParser.composeCardBalance(50_000),
            at: Date().addingTimeInterval(-30 * 24 * 60 * 60),
            note: JournalRecord.manualMarker,
            to: url
        )

        ledger.drain()

        #expect(ledger.cardBalanceMinor == 50_000)
        #expect(JournalStore.readAll(from: url).count == 1)
    }

    // MARK: - Payments

    /// A payment is the one movement that comes off both figures: the bank, because the money
    /// left it, and the month's spend, because it settles charges already counted there.
    @Test func aPaymentComesOffTheBank() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(200_000)

        try ledger.appendManual(
            kind: .payment, merchant: "AMEX PAYMENT", amount: "-825.77", date: nil, cardSuffix: "")
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 200_000 - 82_577)

        let rows = txns(container)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.isPayment)
        #expect(row.amountMinor == -82_577)
        #expect(!row.isMoneyIn, "a payment is money going out, so never green")
        // Which is also what puts it in the month's spend: the total sums everything that is
        // not a deposit, and a payment stored negative reduces it without a special case.
        #expect(!row.isDeposit)
    }

    /// The whole path for an Amex payment, through the registry and the drain.
    @Test func anAmexPaymentEmailBecomesAPayment() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(200_000)

        try appendAlert(AmexPaymentParserTests.realPayment, to: url)
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 200_000 - 104_497, "$1,044.97 left the bank")

        let rows = txns(container)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.isPayment)
        #expect(row.cardSuffix == "21006")
        #expect(row.amountMinor == -104_497)
        #expect(!row.isMoneyIn)
        // Not a deposit, which is what puts it into the month's spend as a reduction.
        #expect(!row.isDeposit)
    }

    /// A charge still leaves the bank alone. The distinction the three kinds exist for.
    @Test func aChargeDoesNotTouchTheBank() throws {
        let (ledger, _, url) = try makeStore()
        try ledger.setBankBalance(200_000)
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 200_000)
    }

    /// The whole path for a Fidelity payment, through the registry and the drain — and the one
    /// kind that moves both figures at once.
    ///
    /// The Amex email walked this path first; this is a second source of the same kind, and the
    /// test is here to pin that nothing downstream had to learn where a payment came from for it
    /// to work: both folds ask the kind, never the source.
    @Test func aFidelityPaymentBecomesAPaymentThatMovesBothFigures() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(200_000)

        // A charge first, so the card balance has something for the payment to come off.
        try appendAlert(charge("500.00", "BREEZE*00HS5MV"), to: url)
        try appendAlert(FidelityPaymentParserTests.realPayment, to: url)
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 200_000 - 31_629, "$316.29 left the bank")
        #expect(ledger.cardBalanceMinor == 50_000 - 31_629, "and the same amount came off the card")

        let rows = txns(container)
        #expect(rows.count == 2)
        let payment = try #require(rows.first { $0.isPayment })
        #expect(payment.merchant == "Fidelity payment")
        #expect(payment.cardSuffix == "7224", "the card it settled, as the SMS printed it")
        #expect(payment.amountMinor == -31_629)
        #expect(!payment.isMoneyIn, "a payment is money going out, so never green")

        // And the month is untouched by it, which is the whole difference between the two
        // figures: a payment settles spending that belongs to an earlier month.
        #expect(Txn.spendingTotal(rows) == 50_000)

        // Its line is kept as well, because a payment is a ledger entry and the row has to stay
        // derivable from the text. Three lines, not two: `setBankBalance` journals the balance
        // it was given alongside the two alerts.
        #expect(JournalStore.readAll(from: url).count == 3)
    }

    /// A payment line is kept however old it is, like a charge. Only a body that resolved to no
    /// movement is dropped after the week, and a payment resolves to one.
    @Test func aPaymentLineIsKeptHoweverOld() throws {
        let (ledger, _, url) = try makeStore()
        let longAgo = Date().addingTimeInterval(-365 * 24 * 60 * 60)
        try appendAlert(FidelityPaymentParserTests.realPayment, at: longAgo, to: url)

        let result = ledger.drain()

        #expect(result.journalLinesDropped == 0)
        #expect(JournalStore.readAll(from: url).count == 1)
    }

    // MARK: - Venmo

    /// A Venmo payment becomes an ordinary deposit: a row in the feed, and a move to the bank
    /// in whichever direction the money went. This is the whole path, through the registry and
    /// the drain, rather than the parser on its own.
    @Test func aVenmoPaymentBecomesADepositThatMovesTheBank() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(10_000)

        // The plain-text payload the automation actually hands over, not the raw markup.
        try appendAlert(VenmoAlertParserTests.automationPayloadReceived, to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_800, "$28.00 in")

        try appendAlert(VenmoAlertParserTests.automationPayloadSent, to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_800 - 38_670, "$386.70 out")

        let rows = txns(container)
        #expect(rows.count == 2)
        // Hoisted: `#expect` cannot expand `allSatisfy` with a key path — it sees the rethrows
        // function and demands a `try` that the call does not need.
        let allDeposits = rows.allSatisfy(\.isDeposit)
        #expect(allDeposits, "both directions are deposits, not charges")
        #expect(Set(rows.map(\.merchant))
                == ["Venmo: Patrick Guo - Kimchi red", "Venmo: Patrick Guo - Banff hotel"])
    }

    /// A charge never touches the bank. The other direction of the same rule.
    @Test func chargesLeaveTheBankAlone() throws {
        let (ledger, _, url) = try makeStore()
        try ledger.setBankBalance(100_000)
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 100_000)
    }

    // MARK: - Editing

    private func freshContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([AlertEvent.self, Txn.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
    }

    @Test func anEditChangesTheRowItNamesAndAddsNoSecondRow() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let original = try #require(txns(container).first)
        try ledger.edit(
            original, merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "7224")
        ledger.drain()

        let rows = txns(container)
        #expect(rows.count == 1, "an edit supersedes a row; it does not add one alongside it")
        #expect(rows.first?.merchant == "BREEZE COFFEE")
        #expect(rows.first?.amountMinor == 400)
    }

    /// The user asked for this in as many words: the edit has to be in the journal, so
    /// throwing the store away and replaying the file lands in the same place.
    @Test func anEditSurvivesARebuild() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let chosen = Date(timeIntervalSince1970: 1_780_000_000)
        try ledger.edit(
            try #require(txns(container).first),
            merchant: "BREEZE COFFEE", amount: "4.00", date: chosen, cardSuffix: "9999")
        ledger.drain()

        let rebuiltContainer = try freshContainer()
        let rebuilt = LedgerStore(container: rebuiltContainer, journalURL: url)
        rebuilt.drain()

        let rows = txns(rebuiltContainer)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.merchant == "BREEZE COFFEE")
        #expect(row.amountMinor == 400)
        #expect(row.cardSuffix == "9999")
        #expect(Calendar.current.isDate(row.occurredAt, inSameDayAs: chosen))
    }

    /// The rule the user asked for: a charge that had a time loses it when the date is edited.
    ///
    /// A Fidelity charge alert carries no date, so its row's `occurredAt` is its arrival — a
    /// real time of day, shown as "Alerted". Editing the date replaces that whole value with a
    /// date and no time, so the row stops claiming a time of day nobody ever stated.
    @Test func editingTheDateRemovesTheTimeTheAlertCarried() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let original = try #require(txns(container).first)
        #expect(!original.occurredAtIsFromMessage)
        #expect(original.occurredAt == original.receivedAt)

        let chosen = Date(timeIntervalSince1970: 1_780_000_000)
        try ledger.edit(
            original, merchant: "BREEZE", amount: "2.50", date: chosen, cardSuffix: "7224")
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.occurredAtIsFromMessage, "the row now has a date of its own")
        #expect(Calendar.current.isDate(row.occurredAt, inSameDayAs: chosen))
        #expect(Calendar.current.component(.hour, from: row.occurredAt) == 12,
                "noon is the date-with-no-time convention, so no clock time is claimed")
    }

    /// And clearing the date puts it back to arrival rather than leaving the old one behind.
    @Test func clearingTheDateFallsBackToArrival() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("2.50", "BREEZE"), to: url)
        ledger.drain()

        let original = try #require(txns(container).first)
        try ledger.edit(
            original, merchant: "BREEZE", amount: "2.50",
            date: Date(timeIntervalSince1970: 1_780_000_000), cardSuffix: "7224")
        ledger.drain()

        try ledger.edit(
            try #require(txns(container).first),
            merchant: "BREEZE", amount: "2.50", date: nil, cardSuffix: "7224")
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(!row.occurredAtIsFromMessage)
        #expect(row.occurredAt == row.receivedAt)
    }

    /// An edit of a deposit moves the bank, because the balance is folded from the row's
    /// current amount — not from the amount the line was first written with.
    @Test func editingADepositChangesWhatItDidToTheBank() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.setBankBalance(10_000)
        try appendDeposit("25.00", "ZELLE FROM SAM", to: url)
        ledger.drain()
        #expect(ledger.bankBalanceMinor == 12_500)

        let deposit = try #require(txns(container).first { $0.isDeposit })
        try ledger.edit(
            deposit, merchant: "ZELLE FROM SAM", amount: "40.00", date: nil, cardSuffix: "")
        ledger.drain()

        #expect(ledger.bankBalanceMinor == 14_000)
    }

    /// The row's key comes from its event. Without one there is nothing for a later line to
    /// point at, so the edit is refused rather than written and silently ignored.
    @Test func aRowWithNoEventCannotBeEdited() throws {
        let (ledger, _, _) = try makeStore()
        let orphan = Txn(
            amountMinor: 100, currencyCode: "USD", cardSuffix: "", merchant: "ORPHAN",
            receivedAt: Date(), occurredAt: Date(), occurredAtIsFromMessage: false,
            parserVersion: 1)

        #expect(orphan.occurrenceKey == nil)
        #expect(throws: LedgerStore.EditError.self) {
            try ledger.edit(orphan, merchant: "X", amount: "1.00", date: nil, cardSuffix: "")
        }
    }

    // MARK: - Categories

    /// Writes an instruction line straight into the journal.
    ///
    /// How a line written by another version of the app arrives, and how these tests say what
    /// the journal holds without going through the writers that are themselves under test.
    private func appendInstruction(_ body: String, to url: URL) throws {
        // Stamped the way every instruction writer in the app stamps it. Without the marker the
        // drain reads the line as a captured body — which is the whole point of the marker — and
        // a fixture that omitted it would be testing a line the app cannot produce.
        try appendRecord(
            body, runID: UUID(), phase: JournalRecord.capturePhase, at: Date(),
            note: JournalRecord.manualMarker, to: url)
    }

    private func journalBodies(_ url: URL) -> [String] {
        JournalStore.readAll(from: url).map(\.trimmedBody)
    }

    /// The occurrence key of the one row in the store — the name a category line addresses.
    private func key(of container: ModelContainer) throws -> String {
        try #require(txns(container).first?.occurrenceKey)
    }

    @Test func aMerchantRuleFilesACharge() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        try appendInstruction("MerchantCategory | grocery | ai | WHOLE FOODS MKT", to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.categoryRaw == "grocery")
        #expect(row.categorySourceRaw == "ai")
        #expect(row.categoryName == "Grocery")
        #expect(!row.categoryWasSetByPerson)
    }

    /// The reason the key is normalised at all: one answer about a shop covers every way the
    /// sources spelled it — including a spelling that had not arrived when the answer was given.
    @Test func oneRuleCoversEverySpellingOfOneMerchant() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        // Answered about one spelling...
        try appendInstruction("MerchantCategory | grocery | ai | WHOLE FOODS MKT #12", to: url)
        ledger.drain()

        // ...and a differently spelled charge arrives afterwards.
        try appendAlert(charge("8.00", "WHOLE FOODS MKT #1234"), to: url)
        ledger.drain()

        let rows = txns(container)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.categoryRaw == "grocery" }, "\(rows.map(\.categoryRaw))")
    }

    /// Specificity beats recency. The rule line is *later in the file* and still loses, because
    /// a statement about one purchase outranks a statement about a shop.
    @Test func aRowTheUserFiledBeatsALaterRuleForItsMerchant() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try ledger.setCategory(row, label: "grocery")
        ledger.drain()

        try appendInstruction("MerchantCategory | retail | ai | AMAZON", to: url)
        ledger.drain()

        let after = try #require(txns(container).first)
        #expect(after.categoryRaw == "grocery", "a rule rewrote a row the user had filed")
        #expect(after.categorySourceRaw == "user")
    }

    /// A person beats the model, in either order. The model's answers arrive asynchronously and
    /// after the fact, so "newest wins" would let a guess overwrite a decision.
    @Test func aPersonsRuleBeatsTheModelsWhicheverCameLast() throws {
        for userFirst in [true, false] {
            let (ledger, container, url) = try makeStore()
            try appendAlert(charge("42.00", "CHICK-FIL-A"), to: url)
            ledger.drain()

            let ai = "MerchantCategory | retail | ai | CHICK-FIL-A"
            let person = "MerchantCategory | dining | user | CHICK-FIL-A"
            for line in userFirst ? [person, ai] : [ai, person] {
                try appendInstruction(line, to: url)
            }
            ledger.drain()

            let row = try #require(txns(container).first)
            #expect(row.categoryRaw == "dining", "userFirst=\(userFirst)")
            #expect(row.categorySourceRaw == "user")
        }
    }

    /// The distinction the empty label exists for. Without it a single row could never be taken
    /// back out of a rule the user set deliberately.
    @Test func clearingOneRowTakesItOutOfItsMerchantsRule() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        try appendAlert(charge("9.00", "AMAZON"), to: url)
        ledger.drain()

        try appendInstruction("MerchantCategory | retail | user | AMAZON", to: url)
        ledger.drain()
        #expect(txns(container).allSatisfy { $0.categoryRaw == "retail" })

        let one = try #require(txns(container).first)
        try ledger.setCategory(one, label: nil)
        ledger.drain()

        let rows = txns(container)
        #expect(rows.filter { $0.categoryRaw.isEmpty }.count == 1, "the cleared row")
        #expect(rows.filter { $0.categoryRaw == "retail" }.count == 1, "the other row keeps the rule")
    }

    /// A second line about the same row supersedes the first — the append-and-supersede idiom
    /// the balance fold uses, with file position as the only order there is.
    @Test func aSecondCategoryLineSupersedesTheFirst() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "BREEZE"), to: url)
        ledger.drain()

        try appendInstruction("Category | \(try key(of: container)) | dining | user", to: url)
        try appendInstruction("Category | \(try key(of: container)) | grocery | user", to: url)
        ledger.drain()

        #expect(txns(container).first?.categoryRaw == "grocery")
    }

    /// The whole reason a category is a journal line rather than a property. The store is
    /// deleted and replayed on any schema change, so a value that lived only on the row would
    /// work perfectly until the first rename and then be gone with nothing to restore it from.
    @Test func aCategorySurvivesARebuild() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try ledger.setCategory(row, label: "grocery")
        try appendInstruction("MerchantCategory | dining | ai | CHICK-FIL-A", to: url)
        ledger.drain()

        // Every row gone, exactly as `resetStoreIfSchemaChanged` leaves things.
        let rebuiltContainer = try freshContainer()
        LedgerStore(container: rebuiltContainer, journalURL: url).drain()

        let rows = txns(rebuiltContainer)
        #expect(rows.count == 1)
        let rebuilt = try #require(rows.first)
        #expect(rebuilt.categoryRaw == "grocery")
        #expect(rebuilt.categorySourceRaw == "user")
    }

    /// Only a charge is spending. A payment is a card being settled and a deposit is money
    /// arriving; filing either under a spending category would make that category's total a
    /// lie, and the rule that matches their merchant must not reach them.
    /// **A payment is never filed; a deposit is.** A payment is a card being settled rather than
    /// a purchase, so a category on one would make that figure a lie. A deposit is money moving —
    /// often for something specific, like a Venmo note that says "Dinner" — and the kind of
    /// movement does not decide whether the row has a subject.
    @Test func aPaymentIsNeverFiledAndADepositIs() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManual(
            kind: .payment, merchant: "AMEX PAYMENT", amount: "-825.77", date: nil, cardSuffix: "")
        try ledger.appendManual(
            kind: .deposit, merchant: "ZELLE FROM SAM", amount: "25.00", date: nil, cardSuffix: "")
        ledger.drain()

        try appendInstruction("MerchantCategory | miscellaneous | ai | AMEX PAYMENT", to: url)
        try appendInstruction("MerchantCategory | miscellaneous | ai | ZELLE FROM SAM", to: url)
        ledger.drain()

        let rows = txns(container)
        #expect(rows.count == 2)
        let payment = try #require(rows.first { $0.isPayment })
        let deposit = try #require(rows.first { $0.isDeposit })

        #expect(!payment.isCategorizable)
        #expect(payment.categoryRaw.isEmpty, "a card payoff was filed as spending")

        #expect(deposit.isCategorizable)
        #expect(deposit.categoryRaw == "miscellaneous")
    }

    /// The note is the categorisation key for a person-to-person row, not the person. A rule
    /// written against the note covers every Venmo with that note, whoever sent it.
    @Test func aVenmoIsFiledByItsNoteNotByThePerson() throws {
        let (ledger, container, url) = try makeStore()
        try ledger.appendManualEntry(VenmoAlertParserTests.receivedWithNote)
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.isDeposit)
        #expect(row.isCategorizable)
        #expect(row.categorizationMerchant == "Kimchi red")
        #expect(!row.categorizationMerchant.contains("Sarvesh"),
                "the person is not part of the key")

        try appendInstruction("MerchantCategory | dining | ai | Dinner", to: url)
        ledger.drain()
        #expect(row.categoryRaw.isEmpty, "a different note must not match")

        try appendInstruction("MerchantCategory | dining | ai | Kimchi red", to: url)
        ledger.drain()
        #expect(row.categoryRaw == "dining")
    }

    /// A Venmo with no note has nothing to categorise by, and must not fall back to the person's
    /// name — the name is not a description of what was bought.
    ///
    /// Tested on the identity functions rather than through a captured body: there is no no-note
    /// fixture, and the rule being pinned is the derivation itself.
    @Test func aVenmoWithNoNoteHasNothingToKeyOn() {
        #expect(VenmoAlertParser.note(fromMerchant: "Venmo: Sarvesh Gade - Kimchi red")
                == "Kimchi red")
        #expect(VenmoAlertParser.note(fromMerchant: "Venmo: Sarvesh Gade") == "")
        #expect(VenmoAlertParser.note(fromMerchant: "BREEZE COFFEE") == nil)

        // Empty for a note-less Venmo — deliberately *not* the descriptor, or a real person's
        // name would become the categorisation key.
        #expect(CategorizationIdentity.merchant(for: "Venmo: Sarvesh Gade") == "")
        #expect(CategorizationIdentity.merchant(for: "Kimchi red") == "Kimchi red")
        #expect(CategorizationIdentity.merchant(for: "WHOLE FOODS MKT") == "WHOLE FOODS MKT")
    }

    /// Deleting the line is the whole undo. `applyCategories` recomputes from scratch on every
    /// drain, so having one fewer line is all it takes — nothing has to be un-applied.
    @Test func deletingTheCategoryLineHandsTheRowBackToItsMerchantRule() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try appendInstruction("MerchantCategory | retail | user | AMAZON", to: url)
        try ledger.setCategory(row, label: "grocery")
        ledger.drain()
        #expect(txns(container).first?.categoryRaw == "grocery")

        let override = try #require(
            JournalStore.readAll(from: url).last { $0.trimmedBody.hasPrefix("Category |") })
        try ledger.deleteJournalLine(override)
        ledger.drain()

        // Back to the merchant rule, not to nothing — which is what "delete the line" means.
        #expect(txns(container).first?.categoryRaw == "retail")
    }

    /// A line naming a row is addressed to that row, so when the transaction goes the line can
    /// never match anything again — and instruction lines are kept forever, so it would sit in
    /// the file being re-read on every drain for the life of the app.
    @Test func deletingATransactionTakesItsCategoryLineWithIt() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try ledger.setCategory(row, label: "grocery")
        try appendInstruction("MerchantCategory | retail | user | AMAZON", to: url)
        ledger.drain()
        #expect(journalBodies(url).contains { $0.hasPrefix("Category |") })

        try ledger.delete([row])

        #expect(txns(container).isEmpty)
        #expect(!journalBodies(url).contains { $0.hasPrefix("Category |") },
                "the category line outlived the row it named")
        // The rule is about the shop, not the row, so it stays.
        #expect(journalBodies(url).contains { $0.hasPrefix("MerchantCategory |") })
    }

    /// A category line is stamped `manualMarker` — the app writing to its own journal is not a
    /// source sending text — so it must not be mistaken for a hand-typed transaction.
    @Test func filingACategoryIsNotAManualEntry() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        let typedAt = ledger.diagnostics().lastManualEntry
        #expect(typedAt == nil)

        let row = try #require(txns(container).first)
        try ledger.setCategory(row, label: "retail")
        ledger.drain()

        #expect(ledger.diagnostics().lastManualEntry == nil)
        #expect(ledger.diagnostics().lastCapture != nil, "the capture is still the capture")
    }

    /// The fold runs after the edits, so a rule is matched against the merchant the row ended
    /// up with rather than the one it was captured under.
    @Test func correctingAMerchantRefilesTheRow() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("4.00", "BREEZE*00HS5MV"), to: url)
        ledger.drain()

        try appendInstruction("MerchantCategory | dining | user | BREEZE COFFEE", to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.categoryRaw.isEmpty, "the captured spelling matches nothing")

        try ledger.edit(row, merchant: "BREEZE COFFEE", amount: "4.00", date: nil, cardSuffix: "7224")
        ledger.drain()

        #expect(txns(container).first?.categoryRaw == "dining")
    }

    /// A rule naming no merchant would match every row whose key is empty — one line filing the
    /// whole ledger. Refused at the writer and again in the fold.
    @Test func aMerchantRuleWithNoMerchantIsRefused() throws {
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        #expect(throws: LedgerStore.CategoryError.self) {
            try ledger.setMerchantRule(merchant: "   ", label: "retail")
        }
        try appendInstruction("MerchantCategory | retail | ai |  ", to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        #expect(row.categoryRaw.isEmpty)
    }
}
