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
nonisolated enum ManualEntryParser {

    static let version = 1

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
        date: Date,
        cardSuffix: String
    ) -> String {
        let fields = [
            prefix,
            amount.trimmingCharacters(in: .whitespacesAndNewlines),
            dateFormatter.string(from: date),
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
        // `omittingEmptySubsequences: false` so a merchant that happens to be blank still
        // yields five fields and is then rejected on its own merits, rather than silently
        // shifting the date into the merchant slot.
        let fields = line
            .split(separator: "|", maxSplits: 4, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count == 5,
              fields[0].lowercased() == prefix.lowercased(),
              let amountMinor = Money.minorUnits(from: fields[1]),
              let date = dateFormatter.date(from: fields[2]),
              isValidCardSuffix(fields[3]),
              !fields[4].isEmpty
        else { return nil }

        return ParsedAlert(
            kind: .charge,
            amountMinor: amountMinor,
            currencyCode: "USD",
            cardSuffix: fields[3],
            merchant: fields[4],
            rawVerb: "charged",
            // The typed date is a date and not a time, so noon — the same convention the Amex
            // parser uses, and for the same reason: a later timezone shift must not drag the
            // row onto the previous day. The feed will label it "Purchased".
            occurredAt: Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date),
            parserVersion: version
        )
    }

    /// At least four digits and at most five, and nothing but digits.
    ///
    /// The form enforces this too, but the check lives here as well: the journal is a text
    /// file, and a line can reach this parser without ever having passed through the form.
    static func isValidCardSuffix(_ value: String) -> Bool {
        guard value.count >= minimumCardDigits, value.count <= maximumCardDigits else { return false }
        // ASCII digits specifically. `Character.isNumber` is true for full-width and other
        // Unicode digits, which would pass here and then never match a captured suffix —
        // the same trap the Fidelity parser avoids by matching `[0-9]` rather than `\d`.
        return value.allSatisfy { $0.isASCII && $0.isNumber }
    }
}
