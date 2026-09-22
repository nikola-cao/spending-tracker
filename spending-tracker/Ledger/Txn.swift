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

    /// Named `uuid`, not `id` — see the note on `AlertEvent.uuid`.
    var uuid: UUID = UUID()

    /// Minor units — cents. Never `Decimal` and never `Double`: SwiftData stores `Decimal`
    /// as a SQLite REAL, which loses precision, and a float loses cents outright.
    var amountMinor: Int = 0

    /// Always "USD". The card only ever alerts in dollars, so there is no conversion
    /// anywhere; the field exists so a stored row is self-describing rather than relying on
    /// a reader knowing that.
    var currencyCode: String = "USD"

    var cardLast4: String = ""

    /// The issuer's descriptor, exactly as received — including its truncations, `*` store
    /// codes, and trailing store numbers. NOT prettified: a display name is a separate,
    /// later concern, and rewriting this would destroy the only ground truth we have.
    var merchant: String = ""

    /// Alert arrival time. The message carries no timestamp of its own.
    var occurredAt: Date = Date()

    var parserVersion: Int = 0

    /// Set when an identical-looking charge already exists close by in time. **Flagged,
    /// never merged.** Two identical charges are two real charges; silently collapsing them
    /// loses money invisibly, while a spurious flag costs one tap.
    var possibleDuplicate: Bool = false

    var event: AlertEvent?

    init(
        amountMinor: Int,
        currencyCode: String,
        cardLast4: String,
        merchant: String,
        occurredAt: Date,
        parserVersion: Int
    ) {
        self.amountMinor = amountMinor
        self.currencyCode = currencyCode
        self.cardLast4 = cardLast4
        self.merchant = merchant
        self.occurredAt = occurredAt
        self.parserVersion = parserVersion
    }
}

extension Txn {
    /// Builds a ledger row from a parsed alert.
    convenience init(from alert: ParsedAlert, occurredAt: Date) {
        self.init(
            amountMinor: alert.amountMinor,
            currencyCode: alert.currencyCode,
            cardLast4: alert.cardLast4,
            merchant: alert.merchant,
            occurredAt: occurredAt,
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
