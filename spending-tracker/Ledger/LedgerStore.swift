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
/// The journal stays the source of truth. If this is ever wrong, the journal can be replayed.
@MainActor
final class LedgerStore {

    struct DrainResult: Equatable {
        var recordsRead = 0
        var eventsAdded = 0
        var transactionsAdded = 0
        var needsReview = 0
    }

    private let container: ModelContainer
    private let journalURL: URL

    init(container: ModelContainer, journalURL: URL = JournalLocation.fileURL) {
        self.container = container
        self.journalURL = journalURL
    }

    /// Two charges that look identical this close together are probably the same event
    /// arriving twice. Flagged, never merged — see `Txn.possibleDuplicate`.
    private static let duplicateWindow: TimeInterval = 300

    /// Reads the journal and adds anything not already recorded. Idempotent, so it is safe to
    /// call on every foreground.
    @discardableResult
    func drain() -> DrainResult {
        var result = DrainResult()

        let records = JournalStore.readAll(from: journalURL)
        guard !records.isEmpty else { return result }
        result.recordsRead = records.count

        let context = container.mainContext
        var known = knownHashes(in: context)

        for record in records {
            // The intent writes an `enter`/`result` pair per alert and both carry the same
            // body, so the hash collapses them to one event. It also collapses a genuine
            // redelivery, which is the point of hashing the raw text rather than the fields.
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }

            let hash = Self.contentHash(body)
            guard !known.contains(hash) else { continue }
            known.insert(hash)

            let event = AlertEvent(
                receivedAt: record.receivedAt,
                body: body,
                contentHash: hash,
                parseState: .needsReview,
                parserVersion: FidelityAlertParser.version
            )
            context.insert(event)
            result.eventsAdded += 1

            guard let alert = FidelityAlertParser.parseFirst(body), alert.isCharge else {
                // Unparsed, or parsed as something that is not a charge. The raw text is
                // kept and the event is shown for review; no ledger row is derived.
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

        try? context.save()
        return result
    }

    /// How many events are recorded. Used by tests and the diagnostics row.
    func eventCount() -> Int {
        (try? container.mainContext.fetchCount(FetchDescriptor<AlertEvent>())) ?? 0
    }

    func transactionCount() -> Int {
        (try? container.mainContext.fetchCount(FetchDescriptor<Txn>())) ?? 0
    }

    // MARK: - Internals

    private func knownHashes(in context: ModelContext) -> Set<String> {
        let events = (try? context.fetch(FetchDescriptor<AlertEvent>())) ?? []
        return Set(events.map(\.contentHash))
    }

    /// True when a same-looking charge already exists within `duplicateWindow`.
    ///
    /// Windowed on purpose: two identical amounts at the same merchant *hours* apart are two
    /// real purchases, and flagging those would train the flag to be ignored. Note this only
    /// ever catches a *near*-identical pair — a byte-identical redelivery is already dropped
    /// by the content hash before it reaches here.
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

    /// SHA-256 of the raw body. Stable across runs and platforms, and never stored as
    /// `@Attribute(.unique)` — the uniqueness is enforced by looking it up, not by the store.
    static func contentHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
