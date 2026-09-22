//
//  ParsedAlert.swift
//  spending-tracker
//
//  The value type that crosses the parse boundary.
//

import Foundation

/// One recognised card alert, extracted from a raw message body.
///
/// A `Sendable` value type on purpose. When the ledger lands (Stage 3) this is what crosses
/// from the parsing layer into persistence; SwiftData models must never cross an actor or a
/// context boundary, so the boundary is drawn here instead.
///
/// `nonisolated` because this target defaults every unannotated type to `@MainActor`, and a
/// pure data type that can only be constructed on the main actor is a trap waiting to happen.
nonisolated struct ParsedAlert: Sendable, Equatable {

    /// What kind of alert this is. Only charges are in scope — the card is configured to
    /// alert on charges and those are the only texts received — but an unrecognised verb is
    /// modelled rather than coerced into `.charge`, because a format change is exactly the
    /// failure that would otherwise corrupt the ledger silently.
    enum Kind: String, Sendable {
        case charge
        case unrecognizedVerb
    }

    let kind: Kind

    /// Minor units (cents), never `Decimal` and never `Double`. SwiftData stores `Decimal`
    /// as a SQLite REAL, which loses precision; integer cents is exact and compares cleanly.
    let amountMinor: Int

    let currencyCode: String

    /// The last four digits of the card. This is the only card identity in the message —
    /// there is no account id and no transaction id.
    let cardLast4: String

    /// The merchant descriptor exactly as the issuer sent it, including its prefixes
    /// (`SQ *`, `PICKUP* `), trailing store numbers, and any truncation. It is NOT
    /// prettified: the issuer's string is the only ground truth, and a display name is a
    /// separate, later concern.
    let merchant: String

    /// The verb as received, lowercased. Kept so an unrecognised verb is visible in the data
    /// rather than only in a log.
    let rawVerb: String

    /// Stamped on every result so rows parsed by an older pattern table are identifiable
    /// after a fix. Because the raw journal is append-only and retained, a corrected parser
    /// can replay history and repair past rows.
    let parserVersion: Int

    var isCharge: Bool { kind == .charge }
}
