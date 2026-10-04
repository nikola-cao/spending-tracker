//
//  Txn.swift
//  spending-tracker
//
//  What we concluded. The ledger the user reads.
//

import Foundation
import SwiftData

/// A parsed movement of money: a card charge, or a deposit into or out of the bank.
///
/// **Invariant: this table contains only real movements of money.** An alert that resolved to
/// nothing — a decline, a merchant's own receipt for a purchase already recorded — lives in
/// `AlertEvent` with no `Txn`. That is deliberate: a forgotten predicate is how unparsed rows
/// would silently pollute a total, and a wrong total is invisible.
///
/// The two kinds are not interchangeable, so anything asking "how much was spent" has to say
/// so — see `isDeposit`. The month total does; the feed does not, because it shows everything.
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
    ///
    /// **Signed.** A refund is a negative charge, and a deposit goes whichever way the money
    /// did, so this is the amount as it was entered rather than a magnitude.
    var amountMinor: Int = 0

    /// Which of the two this row is, as the raw string the journal records.
    ///
    /// Stored as a string rather than as the enum so the journal line and the row can never
    /// disagree about how the value is spelled; read it through `isDeposit`.
    var kindRaw: String = ParsedAlert.Kind.charge.rawValue

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

    /// `kind` defaults to a charge because that is what almost every row is, and because a
    /// test constructing a row to check ordering or a total should not have to state it.
    init(
        amountMinor: Int,
        currencyCode: String,
        cardSuffix: String,
        merchant: String,
        receivedAt: Date,
        occurredAt: Date,
        occurredAtIsFromMessage: Bool,
        parserVersion: Int,
        kind: ParsedAlert.Kind = .charge
    ) {
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.cardSuffix = cardSuffix
        self.merchant = merchant
        self.receivedAt = receivedAt
        self.occurredAt = occurredAt
        self.occurredAtIsFromMessage = occurredAtIsFromMessage
        self.parserVersion = parserVersion
        self.kindRaw = kind.rawValue
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
            parserVersion: alert.parserVersion,
            kind: alert.kind
        )
    }

    /// The key this row was deduped on, and the name an edit uses to reach it — `runID#index`.
    ///
    /// Nil for a row whose event has gone, which an edit then simply cannot address. That is
    /// the honest outcome rather than a guess: the key is the only thing tying a later line
    /// back to the record it changes.
    var occurrenceKey: String? {
        guard let event else { return nil }
        return "\(event.runID.uuidString)#\(event.matchIndex)"
    }

    /// True when this row is money **arriving** rather than money leaving.
    ///
    /// The sign decides, not the kind. A deposit is usually money in and a refund is money
    /// back, so both come out true — but a deposit can be negative, and that is money leaving
    /// the bank. Colouring it as money-in because it happens to be a deposit would say the
    /// opposite of what it means.
    ///
    /// A payment is never money in, whatever its sign. It can only be money going out to settle
    /// a card — and since it is stored negative, the naive rule would have coloured every
    /// payment green.
    var isMoneyIn: Bool {
        if isPayment { return false }
        return isDeposit ? amountMinor > 0 : amountMinor < 0
    }

    /// True when this row is money moving in or out of the bank rather than a card charge.
    ///
    /// The distinction the two kinds exist for. Anything counting *spending* has to ask — the
    /// month total does — while the feed shows both, because both are things that happened.
    var isDeposit: Bool { kindRaw == ParsedAlert.Kind.deposit.rawValue }

    /// True when this row is a card being paid off.
    ///
    /// The third kind, and the only one that comes off the spend *and* the bank: a charge is
    /// owed, a deposit is money arriving, and a payment settles what was owed.
    var isPayment: Bool { kindRaw == ParsedAlert.Kind.payment.rawValue }

    /// Just the rows belonging to the same calendar month as `date`.
    ///
    /// **A filter, never a deletion.** Every row stays in the store, so the month rolling over
    /// costs nothing and loses nothing — a previous-months view has all the history it needs,
    /// and the bank balance is unaffected because it is folded from the journal rather than
    /// from these rows.
    ///
    /// `occurredAt` is the right key for the same reason the total uses it: a charge belongs to
    /// the month it was *made* in, not the month we heard about it. A purchase on the 31st that
    /// arrives on the 1st stays in the month it was spent.
    ///
    /// Nothing is scheduled. The caller passes `date` and the result changes the moment that
    /// date crosses a month boundary, so the rollover happens on the first render after
    /// midnight on the 1st with no timer to get out of step.
    static func inMonth(of date: Date, from txns: [Txn]) -> [Txn] {
        let calendar = Calendar.current
        return txns.filter { calendar.isDate($0.occurredAt, equalTo: date, toGranularity: .month) }
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
