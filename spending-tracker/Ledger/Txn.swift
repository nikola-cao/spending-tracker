//
//  Txn.swift
//  spending-tracker
//
//  What we concluded. The ledger the user reads.
//

import Foundation
import SwiftData

/// A parsed card charge.
///
/// **Invariant: this table contains only charges.** An alert that did not resolve to a charge
/// lives in `AlertEvent` with no `Txn`, so a query over `Txn` needs no predicate to exclude
/// anything. That is deliberate — a forgotten predicate is how unparsed rows would silently
/// pollute a total, and a wrong total is invisible.
///
/// Named `Txn` rather than `Transaction` because SwiftUI already has a `Transaction` type.
@Model
final class Txn {

    /// Named `uuid`, not `id` — `PersistentModel` already provides `id` as a
    /// `PersistentIdentifier`, and declaring our own `id` shadows that conformance and breaks
    /// `ForEach`.
    var uuid: UUID = UUID()

    /// Minor units — cents. Never `Decimal` and never `Double`: SwiftData stores `Decimal`
    /// as a SQLite REAL, which loses precision, and a float loses cents outright.
    var amountMinor: Int = 0

    /// Always "USD". No card here alerts in anything else, so there is no conversion
    /// anywhere; the field exists so a stored row is self-describing rather than relying on
    /// a reader knowing that.
    var currencyCode: String = "USD"

    /// The trailing digits of the card **as the source printed them** — four from the Fidelity
    /// SMS (`ending in 7224`), five from the Amex email (`Account Ending: 21008`). Stored
    /// verbatim rather than normalised to four, because truncating would eventually make two
    /// different cards look identical.
    var cardSuffix: String = ""

    /// The descriptor exactly as the source sent it — Amex's clean merchant name, or the
    /// Fidelity issuer's pre-truncated descriptor with its `*` store codes. NOT prettified:
    /// a display name is a separate, later concern, and rewriting this would destroy the only
    /// ground truth we have.
    var merchant: String = ""

    /// When the alert **arrived** — the Shortcut handing it to the app.
    ///
    /// This is the feed's sort key. Kept separate from `occurredAt` because the two answer
    /// different questions, and only this one is always present.
    ///
    /// It has to be its own field. Sorting on `occurredAt` meant every Amex row on a given day
    /// shared one identical value — the message prints a date and no time, so the parsed value
    /// lands at noon — and identical sort keys leave the order arbitrary, which put new rows
    /// *underneath* older ones. Arrival order is what the user actually reads the list for.
    var receivedAt: Date = Date()

    /// The best-known time of the purchase.
    ///
    /// For a source that prints a date (Amex), that date. Otherwise the moment the alert
    /// arrived. The two are not the same claim, which is why `occurredAtIsFromMessage`
    /// exists and why the row labels them differently.
    ///
    /// Display only — never sort on this.
    var occurredAt: Date = Date()

    /// True when `occurredAt` came from the message rather than from arrival.
    ///
    /// Worth keeping because arrival is a genuinely weaker signal for email: Apple Mail
    /// fetches Gmail on a schedule instead of by push, so an alert can land well after the
    /// purchase. Showing that arrival time unlabelled would misstate when the money was spent.
    var occurredAtIsFromMessage: Bool = false

    var parserVersion: Int = 0

    /// Set when an identical-looking charge already exists close by in time. **Flagged,
    /// never merged.** Two identical charges are two real charges; silently collapsing them
    /// loses money invisibly, while a spurious flag costs one tap.
    var possibleDuplicate: Bool = false

    var event: AlertEvent?

    init(
        amountMinor: Int,
        currencyCode: String,
        cardSuffix: String,
        merchant: String,
        receivedAt: Date,
        occurredAt: Date,
        occurredAtIsFromMessage: Bool,
        parserVersion: Int
    ) {
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.cardSuffix = cardSuffix
        self.merchant = merchant
        self.receivedAt = receivedAt
        self.occurredAt = occurredAt
        self.occurredAtIsFromMessage = occurredAtIsFromMessage
        self.parserVersion = parserVersion
    }
}

extension Txn {
    /// Builds a ledger row from a parsed alert.
    ///
    /// `occurredAt` falls back to `receivedAt` only when the message carried no date of its
    /// own — the Fidelity SMS. `receivedAt` is always the arrival, and is what the feed sorts on.
    convenience init(from alert: ParsedAlert, receivedAt: Date) {
        self.init(
            amountMinor: alert.amountMinor,
            currencyCode: alert.currencyCode,
            cardSuffix: alert.cardSuffix,
            merchant: alert.merchant,
            receivedAt: receivedAt,
            occurredAt: alert.occurredAt ?? receivedAt,
            occurredAtIsFromMessage: alert.occurredAt != nil,
            parserVersion: alert.parserVersion
        )
    }

    /// For display only. `Decimal` avoids the float rounding that minor units exist to
    /// prevent, and `FormatStyle` handles the grouping and symbol.
    var amountDecimal: Decimal { Decimal(amountMinor) / 100 }

    var formattedAmount: String {
        amountDecimal.formatted(.currency(code: currencyCode))
    }
}
