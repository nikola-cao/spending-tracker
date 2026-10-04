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

    /// What kind of alert this is. A deposit only ever comes from the manual form today, but it
    /// is modelled here rather than special-cased downstream because it is a real thing the
    /// ledger holds — and an unrecognised verb is modelled rather than coerced into `.charge`,
    /// because a format change is exactly the failure that would otherwise corrupt the ledger
    /// silently.
    enum Kind: String, Sendable {
        case charge
        case deposit
        /// Paying a card off. Its own kind rather than a large deposit, because it is the one
        /// movement that comes off the *spend* as well as the bank — see `affectsSpend`.
        case payment
        case unrecognizedVerb

        /// Whether this kind becomes a ledger row. Everything but an unrecognised verb does.
        var isLedgerEntry: Bool { self != .unrecognizedVerb }
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

    var isDeposit: Bool { kind == .deposit }

    var isPayment: Bool { kind == .payment }

    /// Whether this moves the bank balance.
    ///
    /// A charge never does — it is owed on a card, not yet paid for. A payment does, because
    /// it is the money actually leaving the bank to settle one.
    var affectsBank: Bool { kind == .deposit || kind == .payment }

    /// Whether this counts against the month's spend.
    ///
    /// A deposit does not: a Zelle received is not a negative cost. A payment does, because it
    /// settles spending that already happened — which is why it *reduces* the figure rather
    /// than adding to it, and why it is stored as a negative amount.
    var affectsSpend: Bool { kind != .deposit }

    /// Whether this alert becomes a ledger row.
    ///
    /// Both a charge and a deposit do. An unrecognised verb does not — it is held as an
    /// `AlertEvent` with no row, which is what keeps `Txn` free of anything that is not a real
    /// movement of money.
    var isLedgerEntry: Bool { kind.isLedgerEntry }
}
