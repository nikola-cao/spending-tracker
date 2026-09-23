//
//  ManualEntryParser.swift
//  spending-tracker
//
//  A charge a person typed, in the same shape as a captured one.
//

import Foundation

/// Reads and writes the canonical line a hand-entered charge is stored as.
///
/// ## Why a text format at all
///
/// The obvious alternative — write the typed fields straight into the store — would make
/// manual charges the one kind of row that is *not* derived from the journal. They would then
/// behave differently from everything else: not restored by a rebuild, not covered by the
/// retention window, not removed when deleted from the feed, and impossible to re-read. That
/// is a lot of special cases for the sake of skipping one format.
///
/// So a manual charge is composed into a line and journalled like any other alert, and this
/// parser reads it back on the next drain. It is the same arrangement the other two sources
/// have: a source is just a parser.
///
/// ## The format
///
///     Manual | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>
///
/// The merchant is **last** on purpose. It is free text a person typed, so it may legitimately
/// contain anything — including the delimiter — and putting it at the end means everything
/// after the fourth field is the merchant, with nothing to escape or reject.
///
/// The date and the card are both **optional**: an empty field means "not given", which is
/// different from a field that is present but wrong. A blank date leaves `occurredAt` nil and
/// the ledger falls back to the moment the entry was made — the same fallback the Fidelity SMS
/// uses, since that carries no date either. A blank card simply leaves the charge without one.
nonisolated enum ManualEntryParser {

    static let version = 2

    /// The leading token that identifies a line as hand-entered. Chosen to read plainly in the
    /// raw journal, where a person may be looking straight at it.
    static let prefix = "Manual"

    /// The bounds the form enforces. Fidelity prints four digits, Amex five, so five is the
    /// ceiling and four the floor — enough to identify a card without storing a whole number.
    static let minimumCardDigits = 4
    static let maximumCardDigits = 5

    private static let dateFormat = "yyyy-MM-dd"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = dateFormat
        return formatter
    }()

    // MARK: - Writing

    /// Composes the line for a hand-entered charge.
    ///
    /// Always use this rather than building the string at the call site: one owner for the
    /// format means the writer and the reader cannot drift apart.
    static func compose(
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) -> String {
        let fields = [
            prefix,
            amount.trimmingCharacters(in: .whitespacesAndNewlines),
            date.map { dateFormatter.string(from: $0) } ?? "",
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
        // `omittingEmptySubsequences: false` so blank optional fields still yield five parts,
        // rather than silently shifting the card into the date slot.
        let fields = line
            .split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count == 5,
              fields[0].lowercased() == prefix.lowercased(),
              let amountMinor = Money.minorUnits(from: fields[1]),
              !fields[4].isEmpty
        else { return nil }

        // A date that is ABSENT is fine; a date that is present but unreadable is not. Falling
        // back to "no date" there would quietly turn a typo into a charge dated today.
        var occurredAt: Date?
        if !fields[2].isEmpty {
            guard let day = dateFormatter.date(from: fields[2]) else { return nil }
            // A date and no time, so noon — the same convention the Amex parser uses, and for
            // the same reason: a later timezone shift must not drag the row onto the day before.
            occurredAt = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }

        let cardSuffix = fields[3]
        guard cardSuffix.isEmpty || isValidCardSuffix(cardSuffix) else { return nil }

        return ParsedAlert(
            kind: .charge,
            amountMinor: amountMinor,
            currencyCode: "USD",
            cardSuffix: cardSuffix,
            merchant: fields[4],
            rawVerb: "charged",
            occurredAt: occurredAt,
            parserVersion: version
        )
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
