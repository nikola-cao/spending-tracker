//
//  ParsedAlert.swift
//  spending-tracker
//
//  The value type that crosses the parse boundary.
//

import Foundation

/// One recognised charge, extracted from a raw message or email body.
///
/// A `Sendable` value type on purpose. The ledger is the only consumer; SwiftData models must
/// never cross an actor or a context boundary, so the boundary is drawn here instead.
///
/// `nonisolated` because this target defaults every unannotated type to `@MainActor`, and a
/// pure data type that can only be constructed on the main actor is a trap waiting to happen.
nonisolated struct ParsedAlert: Sendable, Equatable {

    /// What kind of alert this is. Only charges are in scope, but an unrecognised verb is
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

    /// The trailing digits of the card **exactly as the source printed them**, never
    /// truncated or padded.
    ///
    /// This is not cosmetic. The Fidelity SMS says `ending in 7224` (four digits) while the
    /// Amex email says `Account Ending: 21008` (five). Truncating Amex's to four would work
    /// for the two cards the user has today and silently collide for someone else's, so the
    /// field stores what was given and the name says so.
    let cardSuffix: String

    /// The merchant descriptor exactly as the source sent it — including Amex's clean
    /// merchant name, and including the Fidelity issuer's pre-truncated descriptors with
    /// their `*` store codes. NOT prettified: the issuer's string is the only ground truth.
    let merchant: String

    /// The verb as received, lowercased. Kept so an unrecognised verb is visible in the data
    /// rather than only in a log.
    let rawVerb: String

    /// The transaction time **when the message itself carries one**, otherwise nil.
    ///
    /// The Fidelity SMS carries no timestamp at all, so nil there and the ledger falls back to
    /// arrival time. The Amex email carries a real date, which matters because Apple Mail
    /// fetches Gmail on a schedule rather than by push — an alert can arrive well after the
    /// purchase, so arrival time is the weaker signal when a better one is available.
    let occurredAt: Date?

    /// Stamped on every result so rows parsed by an older pattern table are identifiable, and
    /// history can be re-derived after a fix.
    let parserVersion: Int

    var isCharge: Bool { kind == .charge }
}
