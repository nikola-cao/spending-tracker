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
    /// own, so this is the only time we have — it is the transaction time.
    var receivedAt: Date = Date()

    /// Verbatim. Never normalised, never parsed in place.
    var body: String = ""

    /// SHA-256 of `body`. The real dedup key. A plain indexed String, never `.unique`.
    var contentHash: String = ""

    var parseStateRaw: String = AlertParseState.needsReview.rawValue

    var parserVersion: Int = 0

    /// nil when the body did not resolve to a charge. Cascades, so deleting the event
    /// deletes the transaction derived from it.
    @Relationship(deleteRule: .cascade, inverse: \Txn.event)
    var transaction: Txn?

    init(
        receivedAt: Date,
        body: String,
        contentHash: String,
        parseState: AlertParseState,
        parserVersion: Int
    ) {
        self.receivedAt = receivedAt
        self.body = body
        self.contentHash = contentHash
        self.parseStateRaw = parseState.rawValue
        self.parserVersion = parserVersion
    }

    var parseState: AlertParseState {
        AlertParseState(rawValue: parseStateRaw) ?? .needsReview
    }
}
