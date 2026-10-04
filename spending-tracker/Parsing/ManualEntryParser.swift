//
//  ManualEntryParser.swift
//  spending-tracker
//
//  Something a person typed, in the same shape as a captured one.
//

import Foundation

/// Reads and writes the canonical line a hand-entered charge or deposit is stored as.
///
/// ## Why a text format at all
///
/// The obvious alternative — write the typed fields straight into the store — would make
/// manual entries the one kind of row that is *not* derived from the journal. They would then
/// behave differently from everything else: not restored by a rebuild, not covered by the
/// retention window, not removed when deleted from the feed, and impossible to re-read. That
/// is a lot of special cases for the sake of skipping one format.
///
/// So a manual entry is composed into a line and journalled like any other alert, and this
/// parser reads it back on the next drain. It is the same arrangement the other two sources
/// have: a source is just a parser.
///
/// ## The format
///
///     Manual | <charge|deposit> | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
///
/// The kind is a field of its own rather than a different leading token, so both kinds keep
/// the same six slots and neither needs a reader of its own.
///
/// The merchant is **last** on purpose. It is free text a person typed, so it may legitimately
/// contain anything — including the delimiter — and putting it at the end means everything
/// after the last field is the merchant, with nothing to escape or reject.
///
/// ## Signed amounts, and the older shape
///
/// The amount is parsed by `Money.signedMinorUnits(from:)`, so it may be negative. A refund is
/// a negative charge, and a deposit goes whichever way the money did.
///
/// Lines written before the kind field existed are still read, as charges:
///
///     Manual | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
///
/// The two are told apart by the second field: an amount is never spelled `charge` or
/// `deposit`. Nothing is migrated — the journal is append-only, and a line it already holds
/// has to keep meaning what it meant when it was written.
///
/// The date and the card are both **optional**: an empty field means "not given", which is
/// different from a field that is present but wrong. A blank date leaves `occurredAt` nil and
/// the ledger falls back to the moment the entry was made — the same fallback the Fidelity SMS
/// uses, since that carries no date either. A blank card simply leaves the charge without one.
///
/// A deposit has no card at all, so a deposit line naming one is malformed rather than
/// something to quietly drop.
nonisolated enum ManualEntryParser {

    /// 2 → 3: the kind field was added, and amounts became signed.
    static let version = 3

    /// The leading token that identifies a line as hand-entered. Chosen to read plainly in the
    /// raw journal, where a person may be looking straight at it.
    static let prefix = "Manual"

    /// The bounds the form enforces. Fidelity prints four digits, Amex five, so five is the
    /// ceiling and four the floor — enough to identify a card without storing a whole number.
    static let minimumCardDigits = 4
    static let maximumCardDigits = 5

    // MARK: - Writing

    /// Composes the line for a hand-entered charge or deposit.
    ///
    /// Always use this rather than building the string at the call site: one owner for the
    /// format means the writer and the reader cannot drift apart.
    static func compose(
        kind: ParsedAlert.Kind,
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) -> String {
        let fields = [
            prefix,
            kind.rawValue,
            amount.trimmingCharacters(in: .whitespacesAndNewlines),
            date.map { DayFormat.string(from: $0) } ?? "",
            cardSuffix.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return fields.joined(separator: " | ")
    }

    // MARK: - Reading

    static func parseAll(_ text: String) -> [ParsedAlert] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        for line in lines {
            guard let alert = parse(line) else { continue }
            return [alert]
        }
        return []
    }

    static func parseFirst(_ text: String) -> ParsedAlert? { parseAll(text).first }

    private static func parse(_ line: String) -> ParsedAlert? {
        // Split twice with different limits rather than once and reassembled: `maxSplits` is
        // what keeps the merchant in one piece. Splitting on every pipe and re-joining would
        // silently rewrite a merchant of `A | B` as `A|B`, and the merchant is free text.
        //
        // `omittingEmptySubsequences: false` so blank optional fields still occupy their slots,
        // rather than shifting the card into the date position.
        let wide = fields(of: line, maxSplits: 5)

        // The kind is the second field when it is there. An amount is never spelled "charge" or
        // "deposit", so a legacy line — which holds its amount in that slot — cannot be
        // mistaken for one.
        let hasKind = wide.count >= 6 && ParsedAlert.Kind(rawValue: wide[1]) != nil
        let parts = hasKind ? wide : fields(of: line, maxSplits: 4)
        // +1 for the kind field, which shifts everything after it along by one.
        let shift = hasKind ? 1 : 0

        guard parts.count == 5 + shift,
              parts[0].lowercased() == prefix.lowercased()
        else { return nil }

        // Falling back to `.charge` is not a guess: `hasKind` is only true when the field is a
        // kind this type knows, so the lookup cannot fail here.
        let kind = hasKind ? (ParsedAlert.Kind(rawValue: parts[1]) ?? .charge) : .charge
        // An unrecognised verb is an alert outcome, not something a person can type.
        guard kind.isLedgerEntry else { return nil }

        // Signed: a refund is a negative charge, and a deposit goes either way.
        guard let amountMinor = Money.signedMinorUnits(from: parts[1 + shift]) else { return nil }

        guard !parts[4 + shift].isEmpty else { return nil }

        // A date that is ABSENT is fine; a date that is present but unreadable is not. Falling
        // back to "no date" there would quietly turn a typo into a charge dated today.
        var occurredAt: Date?
        if !parts[2 + shift].isEmpty {
            guard let noon = DayFormat.noon(fromDayText: parts[2 + shift]) else { return nil }
            occurredAt = noon
        }

        let cardSuffix = parts[3 + shift]
        if kind == .charge {
            guard cardSuffix.isEmpty || isValidCardSuffix(cardSuffix) else { return nil }
        } else {
            // A deposit and a payment both have no card, so a line naming one is malformed
            // rather than something to quietly drop.
            guard cardSuffix.isEmpty else { return nil }
        }

        return ParsedAlert(
            kind: kind,
            amountMinor: amountMinor,
            currencyCode: "USD",
            cardSuffix: cardSuffix,
            merchant: parts[4 + shift],
            rawVerb: kind == .deposit ? "deposited" : "charged",
            occurredAt: occurredAt,
            parserVersion: version
        )
    }

    private static func fields(of line: String, maxSplits: Int) -> [String] {
        line
            .split(separator: "|", maxSplits: maxSplits, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// At least four digits and at most five, and nothing but ASCII digits.
    ///
    /// The form enforces this too, but the check lives here as well: the journal is a text
    /// file, and a line can reach this parser without ever having passed through the form.
    /// An empty value is *not* valid here — callers that allow an absent card test for empty
    /// separately, so that "not given" and "given but wrong" stay distinguishable.
    static func isValidCardSuffix(_ value: String) -> Bool {
        guard value.count >= minimumCardDigits, value.count <= maximumCardDigits else { return false }
        // ASCII digits specifically. `Character.isNumber` is true for full-width and other
        // Unicode digits, which would pass here and then never match a captured suffix —
        // the same trap the Fidelity parser avoids by matching `[0-9]` rather than `\d`.
        return value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
