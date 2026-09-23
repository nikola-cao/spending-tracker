//
//  LedgerStore.swift
//  spending-tracker
//
//  Turns the raw journal into ledger rows.
//

import CryptoKit
import Foundation
import SwiftData

/// Drains the append-only journal into SwiftData, and compacts the journal as it goes.
///
/// **The App Intent is deliberately not involved.** It keeps writing raw text to the journal
/// exactly as it did in Stage 1, and this runs in the app when it becomes active. Three
/// reasons that is the better design, not a shortcut:
///
/// 1. The intent is the one component *proven on real hardware* — a locked phone in a pocket,
///    iOS 27, `allowedExecutionTargets = .main`. Nothing downstream needs to touch it, so
///    nothing downstream can break it.
/// 2. Writing to the ledger at capture time buys nothing. The UI only exists while the app is
///    open, so a row written at 2pm and drained at 6pm is indistinguishable from one written
///    at 2pm — you could not have seen it either way.
/// 3. It removes three real hazards at once: `@Dependency` (a non-optional generic with no
///    default init), SwiftData writes from a non-main actor, and a second process opening the
///    same store.
///
/// Adding a second source (Amex email) required no change to this shape at all: a source is a
/// parser, and the journal does not care where a body came from.
///
/// **Only charges reach the ledger; everything else is held in the journal for a week.**
/// The automations also capture a merchant's own confirmation email for a purchase already
/// recorded, statement notices, and OTPs. None of that is ever a ledger row — but it is not
/// discarded on arrival either. Holding it costs nothing in the store and preserves the
/// recovery path: a retained body is re-parsed on every drain, so a charge that starts being
/// recognised within the week is picked up with no special handling. See `nonChargeRetention`.
@MainActor
final class LedgerStore {

    struct DrainResult: Equatable {
        var recordsRead = 0
        var eventsAdded = 0
        var transactionsAdded = 0
        /// Bodies that resolved to no charge, and so were recorded nowhere.
        var notCharges = 0
        /// Journal lines dropped for not being charges and outliving the retention window.
        var journalLinesDropped = 0
        /// Non-nil when the store refused the write. Surfaced in the UI rather than
        /// swallowed: a silent save failure renders a complete-looking ledger that is not on
        /// disk and vanishes at relaunch.
        var saveError: String?
    }

    private let container: ModelContainer
    private let journalURL: URL

    init(container: ModelContainer, journalURL: URL = JournalLocation.fileURL) {
        self.container = container
        self.journalURL = journalURL
    }

    /// Two charges that look identical this close together may be the same event arriving
    /// twice. Flagged, never merged — see `Txn.possibleDuplicate`.
    private static let duplicateWindow: TimeInterval = 300

    /// Reads the journal, records any charge not already recorded, and drops the rest.
    /// Idempotent, so it is safe to call on every foreground.
    ///
    /// Fully synchronous, and therefore non-reentrant by construction: there is no `await`
    /// anywhere below, so the three call sites (`.task`, `scenePhase`, pull-to-refresh) cannot
    /// interleave on the main actor.
    @discardableResult
    func drain() -> DrainResult {
        var result = DrainResult()

        let context = container.mainContext
        let records = JournalStore.readAll(from: journalURL)
        result.recordsRead = records.count

        if !records.isEmpty {
            ingest(records, into: context, result: &result)
        }

        do {
            try context.save()
        } catch {
            // Roll back so the UI cannot render rows that are not on disk, and report it.
            // The journal is untouched, so the next drain retries from scratch.
            context.rollback()
            result.saveError = error.localizedDescription
            return result
        }

        // The purge runs only AFTER the store has accepted the write. If the save failed the
        // journal is the only copy of anything, so nothing may be dropped from it.
        result.journalLinesDropped = purgeExpired(records, now: Date())
        return result
    }

    private func ingest(
        _ records: [JournalRecord],
        into context: ModelContext,
        result: inout DrainResult
    ) {
        var known = knownOccurrences(in: context)

        // One invocation writes an `enter` and a `result` line carrying the same body. For a
        // charge the occurrence key collapses the pair, but a body that is NOT a charge records
        // no key at all — so without this the pair would be parsed, counted and compacted as
        // two separate things.
        var seenInvocations = Set<UUID>()

        for record in records {
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            guard seenInvocations.insert(record.runID).inserted else { continue }

            // Only charges are recorded. The index is the position in the FULL parse rather
            // than in the filtered list, so an occurrence key stays stable if a body's mix of
            // charges and non-charges ever changes.
            let charges = AlertParsers.parseAll(body)
                .enumerated()
                .filter { $0.element.isCharge }

            guard !charges.isEmpty else {
                result.notCharges += 1
                continue
            }

            for (index, alert) in charges {
                // Keyed on the INVOCATION, not the body. See `AlertEvent.occurrenceKey` for
                // why: a body is not unique per transaction, so keying on it silently dropped
                // every repeat charge — a monthly subscription would be recorded once, ever.
                let key = "\(record.runID.uuidString)#\(index)"
                guard !known.contains(key) else { continue }
                known.insert(key)

                let event = AlertEvent(
                    receivedAt: record.receivedAt,
                    runID: record.runID,
                    matchIndex: index,
                    body: body,
                    contentHash: Self.contentHash(body),
                    parseState: .parsed,
                    parserVersion: AlertParsers.version
                )
                context.insert(event)
                result.eventsAdded += 1

                let txn = Txn(from: alert, receivedAt: record.receivedAt)
                // Computed BEFORE the row is inserted or wired up, so the fetch cannot see it.
                txn.possibleDuplicate = hasNearbyEqual(txn, in: context)
                context.insert(txn)

                txn.event = event
                event.transaction = txn
                result.transactionsAdded += 1
            }
        }
    }

    /// How long a body that resolved to no charge is kept before being dropped.
    ///
    /// Charges are kept forever. Everything else — a merchant's own confirmation email for a
    /// purchase already recorded, a statement notice, an OTP — is held for a week and then
    /// purged.
    ///
    /// The window is what preserves the recovery path. A retained body is re-parsed on every
    /// drain, so a charge that starts being recognised within the week is picked up normally,
    /// with no special handling. Past that it is gone, which is the accepted cost of not
    /// carrying junk indefinitely.
    static let nonChargeRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Drops journal lines that resolved to no charge and have outlived the retention window.
    ///
    /// Runs over the records the drain already read, so it costs nothing extra to decide.
    /// `JournalStore.replace` swaps the file in atomically, so an interruption leaves the
    /// original intact. This is the only place in the app that deliberately discards captured
    /// text.
    private func purgeExpired(_ records: [JournalRecord], now: Date) -> Int {
        guard !records.isEmpty else { return 0 }
        let cutoff = now.addingTimeInterval(-Self.nonChargeRetention)

        let kept = records.filter { record in
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            // A charge is kept forever, whenever it arrived.
            if !body.isEmpty, AlertParsers.parseAll(body).contains(where: \.isCharge) {
                return true
            }
            // Anything else — including an empty body — survives only inside the window.
            return record.receivedAt > cutoff
        }

        guard kept.count < records.count else { return 0 }
        do {
            try JournalStore.replace(contentsOf: journalURL, with: kept)
        } catch {
            // Losing a purge is harmless — the same lines are dropped on a later drain.
            return 0
        }
        return records.count - kept.count
    }

    // MARK: - Manual entry

    enum ManualEntryError: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: "There is nothing to record."
            }
        }
    }

    /// Records a message the user typed or pasted.
    ///
    /// Appends to the **journal**, not the store, deliberately: the text then takes the exact
    /// path a captured alert uses, so it is durable, replayable, and cannot drift from the
    /// real ingest. It also means the whole pipeline can be exercised end to end without
    /// waiting for a real purchase.
    @discardableResult
    func appendManualEntry(_ text: String) throws -> UUID {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ManualEntryError.empty }

        let runID = UUID()
        try JournalStore.append(
            .diagnostic(runID: runID, phase: "result", raw: body, note: JournalRecord.manualMarker),
            to: journalURL
        )
        return runID
    }

    // MARK: - Deleting

    /// Removes charges, and the journal lines they came from.
    ///
    /// **The journal edit is not optional.** The store is derived: the drain re-reads the
    /// journal on every foreground and recreates any invocation it does not already know
    /// about, so deleting only the row would have it reappear moments later.
    ///
    /// The journal is written FIRST, and that order matters. If the journal edit lands and the
    /// store delete fails, the row is still on screen and the user can simply delete it again.
    /// The reverse order fails the other way: the row disappears, then silently comes back on
    /// the next drain, which is both confusing and looks like a bug in the app rather than a
    /// failed write.
    @discardableResult
    func delete(_ txns: [Txn]) -> Int {
        guard !txns.isEmpty else { return 0 }
        let context = container.mainContext

        // The event carries the invocation identity; deleting it cascades to its transaction.
        var events: [AlertEvent] = []
        var runIDs = Set<UUID>()
        var orphans: [Txn] = []

        for txn in txns {
            if let event = txn.event {
                events.append(event)
                runIDs.insert(event.runID)
            } else {
                // Should not happen — every charge is derived from an event — but a row that
                // somehow has none must still be deletable.
                orphans.append(txn)
            }
        }

        removeJournalRecords(runIDs: runIDs)

        for event in events { context.delete(event) }
        for txn in orphans { context.delete(txn) }
        try? context.save()

        return events.count + orphans.count
    }

    /// Drops every journal line written by the given invocations.
    ///
    /// Atomic and staged like the retention purge, and for the same reason: the journal is the
    /// only thing here that must never be left half-written.
    private func removeJournalRecords(runIDs: Set<UUID>) {
        guard !runIDs.isEmpty else { return }
        let records = JournalStore.readAll(from: journalURL)
        let kept = records.filter { !runIDs.contains($0.runID) }
        guard kept.count < records.count else { return }
        try? JournalStore.replace(contentsOf: journalURL, with: kept)
    }

    // MARK: - Diagnostics

    struct Diagnostics: Equatable {
        var eventCount = 0
        var transactionCount = 0
        var parserVersion = 0
        var journalLines = 0
        var journalBytes = 0
        var lastCapture: Date?
        var lastManualEntry: Date?
    }

    /// Everything needed to answer "is capture still working, and is the ledger keeping up".
    func diagnostics() -> Diagnostics {
        var result = Diagnostics()
        let context = container.mainContext

        result.eventCount = (try? context.fetchCount(FetchDescriptor<AlertEvent>())) ?? 0
        result.transactionCount = (try? context.fetchCount(FetchDescriptor<Txn>())) ?? 0
        result.parserVersion = AlertParsers.version

        let records = JournalStore.readAll(from: journalURL)
        result.journalLines = records.count
        // Manual entries are excluded: this answers "is the AUTOMATION still capturing".
        result.lastCapture = records.last { $0.note != JournalRecord.manualMarker }?.receivedAt
        result.lastManualEntry = records.last { $0.note == JournalRecord.manualMarker }?.receivedAt

        result.journalBytes = (try? FileManager.default
            .attributesOfItem(atPath: journalURL.path(percentEncoded: false))[.size] as? Int) ?? 0
        return result
    }

    // MARK: - Internals

    private func knownOccurrences(in context: ModelContext) -> Set<String> {
        let events = (try? context.fetch(FetchDescriptor<AlertEvent>())) ?? []
        return Set(events.map(\.occurrenceKey))
    }

    /// True when a same-looking charge already exists within `duplicateWindow`.
    ///
    /// Windowed on purpose. Two identical amounts at the same merchant *hours* apart are two
    /// real purchases — the same coffee bought twice this month — and flagging those would
    /// train the flag to be ignored. This is the only place a repeated charge is treated as
    /// suspicious, and it never discards: both rows are kept and one is labelled.
    ///
    /// Note this compares `merchant` byte-for-byte, which is only meaningful *within* a
    /// source. Amex sends an enriched merchant name and Fidelity sends a truncated issuer
    /// descriptor, so the two can never be equal — two different tools for two different
    /// problems, and mixing them would be a bug.
    ///
    /// The window is measured on `receivedAt`, not `occurredAt`. A redelivery arrives seconds
    /// after the original, which is the thing being detected. Measuring on `occurredAt` would
    /// be wrong for Amex specifically: every row from one day shares the same parsed date, so
    /// the window would call any two same-day charges at one merchant duplicates.
    private func hasNearbyEqual(_ txn: Txn, in context: ModelContext) -> Bool {
        let card = txn.cardSuffix
        let amount = txn.amountMinor
        let merchant = txn.merchant
        let from = txn.receivedAt.addingTimeInterval(-Self.duplicateWindow)
        let to = txn.receivedAt.addingTimeInterval(Self.duplicateWindow)

        let descriptor = FetchDescriptor<Txn>(
            predicate: #Predicate { other in
                other.cardSuffix == card
                    && other.amountMinor == amount
                    && other.merchant == merchant
                    && other.receivedAt >= from
                    && other.receivedAt <= to
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// SHA-256 of the raw body. Stable across runs and platforms. Retained for
    /// cross-referencing — deliberately NOT the dedup key, and deliberately not declared
    /// `@Attribute(.unique)`, whose uniqueness would be enforced by clobbering, not by lookup.
    static func contentHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
