//
//  AlertEvent.swift
//  spending-tracker
//
//  What arrived. The durable form of the raw journal.
//

import Foundation
import SwiftData

/// How far an alert got through the parser.
///
/// Deliberately only two states. The drain parses synchronously, so there is no `pending`;
/// and a body that matches the envelope but carries a verb we do not expect lands in
/// `needsReview` rather than a state of its own, because the two need the same treatment:
/// keep the raw text, derive no transaction, show it to a human.
enum AlertParseState: String, Sendable {
    case parsed
    case needsReview
}

/// One alert message that arrived.
///
/// This is the durable form of the raw journal: what arrived, verbatim, whether or not we
/// could make sense of it. A `Txn` is *derived* from it, and can be re-derived if the parser
/// is ever fixed, because this row is never rewritten.
///
/// Every non-optional property has a default, and nothing is `@Attribute(.unique)`. That is
/// not defensive habit: a non-optional property without a default makes the store fail to
/// load (NSCocoaErrorDomain 134110), and `.unique` silently clobbers the other fields of the
/// row it collides with and permanently blocks CloudKit with 134060.
@Model
final class AlertEvent {

    /// A stable identifier for export and cross-referencing. Named `uuid` rather than `id`
    /// on purpose: `PersistentModel` already provides `id` as a `PersistentIdentifier`, and
    /// declaring our own `id` shadows that conformance and breaks `ForEach`.
    var uuid: UUID = UUID()

    /// When the Shortcut handed us the message. The alert text carries no timestamp of its
    /// own, so this is the only time we have.
    var receivedAt: Date = Date()

    /// The journal invocation that produced this event. Both lines of an `enter`/`result`
    /// pair share it.
    var runID: UUID = UUID()

    /// Which alert within that invocation. One message can carry more than one.
    var matchIndex: Int = 0

    /// Verbatim. Never normalised, never parsed in place.
    var body: String = ""

    /// SHA-256 of `body`. Retained for cross-referencing and debugging. **Not the dedup
    /// key** — see `occurrenceKey`.
    var contentHash: String = ""

    /// **The dedup key.** `"<runID>#<matchIndex>"`.
    ///
    /// Deliberately an *occurrence* identity rather than a *message* identity, because the
    /// message is not unique per transaction. A Fidelity body is a pure function of
    /// (card, amount, merchant) — it carries no transaction id, no sequence, no timestamp —
    /// so a monthly $15.49 at NETFLIX.COM produces a byte-identical string every month. Keyed
    /// on the body, the second month onward was silently dropped: no row, no review entry,
    /// nothing. Keyed on the invocation, a redelivery collapses (the pair shares a `runID`)
    /// while a genuine repeat is recorded, and near-duplicates are caught by
    /// `Txn.possibleDuplicate`, which *flags* instead of discarding.
    var occurrenceKey: String = ""

    var parseStateRaw: String = AlertParseState.needsReview.rawValue

    /// The parser version that last looked at this body. Consulted by the drain so a parser
    /// fix actually repairs history rather than being inert.
    var parserVersion: Int = 0

    /// nil when the body did not resolve to a charge. Cascades, so deleting the event
    /// deletes the transaction derived from it.
    @Relationship(deleteRule: .cascade, inverse: \Txn.event)
    var transaction: Txn?

    init(
        receivedAt: Date,
        runID: UUID,
        matchIndex: Int,
        body: String,
        contentHash: String,
        parseState: AlertParseState,
        parserVersion: Int
    ) {
        self.receivedAt = receivedAt
        self.runID = runID
        self.matchIndex = matchIndex
        self.body = body
        self.contentHash = contentHash
        self.occurrenceKey = "\(runID.uuidString)#\(matchIndex)"
        self.parseStateRaw = parseState.rawValue
        self.parserVersion = parserVersion
    }

    var parseState: AlertParseState {
        AlertParseState(rawValue: parseStateRaw) ?? .needsReview
    }
}
