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
    /// The feed's tie-break, and the whole of its order within a day. See `feedOrder`.
    ///
    /// It has to be its own field. Every Amex row on a given day shares one identical
    /// `occurredAt` — the message prints a date and no time, so the parsed value lands at noon
    /// — and identical sort keys leave the order arbitrary, which put new rows *underneath*
    /// older ones. Arrival order is what the user actually reads the list for.
    var receivedAt: Date = Date()

    /// The best-known time of the purchase.
    ///
    /// For a source that prints a date (Amex), that date. Otherwise the moment the alert
    /// arrived. The two are not the same claim, which is why `occurredAtIsFromMessage`
    /// exists and why the row labels them differently.
    ///
    /// The feed sorts on its calendar **day**, never on the instant — see `feedOrder` for why
    /// the time of day in here cannot be trusted.
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

    /// The feed's order: by the day the charge belongs to, newest first, and within a day by
    /// the order the charges arrived in the app.
    ///
    /// The day is `occurredAt`'s calendar day — the purchase date when the source printed one
    /// (Amex, and a hand-entered date), and the arrival day otherwise, since the Fidelity SMS
    /// carries no date at all.
    ///
    /// Within a day the order is arrival, never a clock time, and that is the whole point. No
    /// row in this ledger has a time of day that means anything: the two sources that print a
    /// date print no time, so both parsers land those at noon, and the SMS prints nothing, so
    /// its `occurredAt` *is* its arrival. Ordering by the instant therefore either compares
    /// identical values or compares a real arrival against a fabricated noon — and the moment
    /// a single date-only row lands in a day it reshuffles the rows around it. Arrival is the
    /// one signal that is always real, and for the SMS it is within seconds of the purchase.
    ///
    /// One comparison over a whole-row key, deliberately, rather than the pairwise rule "both
    /// have times → compare times, otherwise compare arrival". That rule is not transitive —
    /// given A(14:00, arrived 1st), B(16:00, arrived 3rd) and C(date-only, arrived 2nd) it
    /// wants A<B by time, B<C by arrival, and C<A by arrival at once — and an inconsistent
    /// comparator is undefined behaviour inside `sorted(by:)`, not merely a wrong order.
    static func feedOrder(_ txns: [Txn]) -> [Txn] {
        let calendar = Calendar.current
        // Keyed up front rather than inside the comparator, which would recompute the
        // calendar day O(n log n) times.
        return txns
            .map { (day: calendar.startOfDay(for: $0.occurredAt), arrived: $0.receivedAt, txn: $0) }
            .sorted { lhs, rhs in
                if lhs.day != rhs.day { return lhs.day > rhs.day }
                return lhs.arrived > rhs.arrived
            }
            .map(\.txn)
    }

    /// For display only. `Decimal` avoids the float rounding that minor units exist to
    /// prevent, and `FormatStyle` handles the grouping and symbol.
    var amountDecimal: Decimal { Decimal(amountMinor) / 100 }

    var formattedAmount: String {
        amountDecimal.formatted(.currency(code: currencyCode))
    }
}
