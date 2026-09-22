//
//  LedgerStore.swift
//  spending-tracker
//
//  Turns the raw journal into ledger rows.
//

import CryptoKit
import Foundation
import SwiftData

/// Drains the append-only journal into SwiftData.
///
/// **The App Intent is deliberately not involved.** It keeps writing raw text to the journal
/// exactly as it did in Stage 1, and this runs in the app when it becomes active. Three
/// reasons that is the better design, not a shortcut:
///
/// 1. The intent is the one component *proven on real hardware* — a locked phone in a pocket,
///    iOS 27, `allowedExecutionTargets = .main`. Nothing in Stage 3 needs to touch it, so
///    nothing in Stage 3 can break it.
/// 2. Writing to the ledger at capture time buys nothing. The UI only exists while the app is
///    open, so a row written at 2pm and drained at 6pm is indistinguishable from one written
///    at 2pm — you could not have seen it either way.
/// 3. It removes three real hazards at once: `@Dependency` (a non-optional generic with no
///    default init), SwiftData writes from a non-main actor, and a second process opening the
///    same store.
///
/// The journal stays the source of truth. The store is *derived* and can be rebuilt from it.
@MainActor
final class LedgerStore {

    struct DrainResult: Equatable {
        var recordsRead = 0
        var eventsAdded = 0
        var transactionsAdded = 0
        var needsReview = 0
        /// Events re-derived because they were recorded by an older parser.
        var repaired = 0
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

    /// Reads the journal and adds anything not already recorded. Idempotent, so it is safe to
    /// call on every foreground.
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

        // Reprocessing runs even when the journal is empty: an event left unparsed by an older
        // parser must still be repaired, and an early return here would strand it forever.
        if !records.isEmpty {
            ingest(records, into: context, result: &result)
        }
        result.repaired = reprocessStaleEvents(in: context)

        do {
            try context.save()
        } catch {
            // Roll back so the UI cannot render rows that are not on disk, and report it.
            // The journal is untouched, so the next drain retries from scratch.
            context.rollback()
            result.saveError = error.localizedDescription
        }
        return result
    }

    private func ingest(
        _ records: [JournalRecord],
        into context: ModelContext,
        result: inout DrainResult
    ) {
        var known = knownOccurrences(in: context)

        for record in records {
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            // One body can carry more than one alert — bodies have been observed concatenated
            // with no separator. `nil` stands for "nothing recognisable here", so a body that
            // parses to nothing still becomes an event and its raw text is kept for review.
            let parsed = FidelityAlertParser.parseAll(body)
            let matches: [ParsedAlert?] = parsed.isEmpty ? [nil] : parsed

            for (index, alert) in matches.enumerated() {
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
                    parseState: .needsReview,
                    parserVersion: FidelityAlertParser.version
                )
                context.insert(event)
                result.eventsAdded += 1

                guard let alert, alert.isCharge else {
                    result.needsReview += 1
                    continue
                }

                let txn = Txn(from: alert, occurredAt: record.receivedAt)
                // Computed BEFORE the row is inserted or wired up, so the fetch cannot see it.
                txn.possibleDuplicate = hasNearbyEqual(txn, in: context)
                context.insert(txn)

                txn.event = event
                event.transaction = txn
                event.parseStateRaw = AlertParseState.parsed.rawValue
                result.transactionsAdded += 1
            }
        }
    }

    /// Re-derives transactions for events that were recorded by an older parser.
    ///
    /// Without this, "the raw text is kept so a parser fix can recover these" is a promise the
    /// code cannot keep: the occurrence guard skips any event already recorded, so an alert
    /// that failed to parse would stay unparsed forever no matter how good the parser became.
    /// This is what makes the journal genuinely replayable rather than merely retained.
    private func reprocessStaleEvents(in context: ModelContext) -> Int {
        let version = FidelityAlertParser.version
        let descriptor = FetchDescriptor<AlertEvent>(
            predicate: #Predicate { $0.transaction == nil && $0.parserVersion < version }
        )
        guard let stale = try? context.fetch(descriptor), !stale.isEmpty else { return 0 }

        var repaired = 0
        for event in stale {
            event.parserVersion = version
            guard let alert = FidelityAlertParser.parseFirst(event.body), alert.isCharge else { continue }

            let txn = Txn(from: alert, occurredAt: event.receivedAt)
            txn.possibleDuplicate = hasNearbyEqual(txn, in: context)
            context.insert(txn)
            txn.event = event
            event.transaction = txn
            event.parseStateRaw = AlertParseState.parsed.rawValue
            repaired += 1
        }
        return repaired
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
    /// path the automation uses, so it is durable, replayable, and cannot drift from the real
    /// ingest. It also means the whole pipeline can be exercised end to end without waiting
    /// for a real purchase — which, given no live alert has ever flowed through, is most of
    /// its value today.
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

    // MARK: - Diagnostics

    struct Diagnostics: Equatable {
        var eventCount = 0
        var transactionCount = 0
        var needsReviewCount = 0
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
        result.needsReviewCount = result.eventCount - result.transactionCount
        result.parserVersion = FidelityAlertParser.version

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
    private func hasNearbyEqual(_ txn: Txn, in context: ModelContext) -> Bool {
        let card = txn.cardLast4
        let amount = txn.amountMinor
        let merchant = txn.merchant
        let from = txn.occurredAt.addingTimeInterval(-Self.duplicateWindow)
        let to = txn.occurredAt.addingTimeInterval(Self.duplicateWindow)

        let descriptor = FetchDescriptor<Txn>(
            predicate: #Predicate { other in
                other.cardLast4 == card
                    && other.amountMinor == amount
                    && other.merchant == merchant
                    && other.occurredAt >= from
                    && other.occurredAt <= to
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
