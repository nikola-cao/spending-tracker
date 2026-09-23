//
//  AmexAlertParser.swift
//  spending-tracker
//
//  Pure. No store, no UI, no async, no dependency on the automation.
//

import Foundation

/// Extracts a charge from an American Express "large purchase" alert email.
///
/// The shape, captured from the user's real inbox (HTML flattened by `HTMLText`):
///
///     See the details about this purchase
///     NIKOLA CAO
///     Account Ending: 21008
///     There was a large purchase on your Card
///     Dear NIKOLA CAO,
///     As you requested, we're letting you know that this purchase was more than $1.00.
///     You can change the dollar amount of these large purchase notifications online.
///     AIRBNB US SHORT TERM STAY
///     $515.66*
///     Tue, Sep 22, 2026
///     *The amount above may not reflect the final amount ...
///
/// **Parsed line-wise, not with one anchored regex.** The merchant, the amount and the date are
/// three *adjacent lines* in a fixed order, so the structure is the anchor. The HTML offers no
/// semantic hooks — the amount sits in a bare `<p>` styled by inline CSS, and the class names
/// are shared with the boilerplate — so there is nothing else to hold on to.
///
/// **Strict by design, and this is the important part.** The user's Email automation also
/// captures *merchant* confirmation emails — an Airbnb booking receipt and a CinemaPlus ticket
/// receipt were both saved alongside the Amex alerts for the very same purchases, carrying the
/// very same amounts. Anything that merely looked for "a dollar amount in some text" would
/// record every online purchase twice. So this parser refuses anything that does not carry
/// Amex's own envelope sentence, rather than hunting for a number and hoping.
nonisolated enum AmexAlertParser {

    static let version = 1

    /// The discriminator. Amex's exact wording for the "$1.00+" purchase notification, and the
    /// one phrase a merchant receipt will never contain.
    static let envelope = "there was a large purchase on your card"

    /// Amex prints five digits (`Account Ending: 21008`); the Fidelity SMS carries four. Both
    /// are accepted as-is and never truncated — see `ParsedAlert.cardSuffix`.
    private static let accountPattern = try? NSRegularExpression(
        pattern: #"^account ending:\s*([0-9]{4,6})$"#, options: [.caseInsensitive])

    /// A line that is nothing but an amount, with Amex's trailing `*` footnote marker.
    /// Requiring the whole line is what stops a stray figure inside prose from being picked up.
    private static let amountPattern = try? NSRegularExpression(
        pattern: #"^\$([0-9][0-9,]*\.[0-9]{2})\*?$"#)

    /// `Tue, Sep 22, 2026`. Fixed-locale so a device set to another region cannot change how
    /// the month abbreviation is read.
    private static let datePattern = try? NSRegularExpression(
        pattern: #"^[A-Za-z]{3},\s+[A-Za-z]{3}\s+[0-9]{1,2},\s+[0-9]{4}$"#)

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, MMM d, yyyy"
        return formatter
    }()

    /// Every charge in the text. Empty when this is not an Amex purchase alert.
    static func parseAll(_ text: String) -> [ParsedAlert] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // The envelope must be present before anything else is considered at all.
        guard let envelopeIndex = lines.firstIndex(where: { $0.lowercased().contains(envelope) }) else {
            return []
        }

        guard let account = firstMatch(accountPattern, in: lines, from: 0)?.captures.first,
              let amountText = firstMatch(amountPattern, in: lines, from: envelopeIndex)
                  .map({ $0.captures.first ?? "" }),
              let amountMinor = Money.minorUnits(from: amountText),
              let amountIndex = firstMatch(amountPattern, in: lines, from: envelopeIndex)?.index,
              // The merchant is the line directly above the amount — that adjacency is the
              // whole reason this is parsed line-wise rather than by regex over the document.
              amountIndex > 0
        else { return [] }

        let merchant = lines[amountIndex - 1].trimmingCharacters(in: .whitespaces)
        guard let cleanMerchant = cleanMerchant(merchant) else { return [] }

        // The date is optional: it improves the row but its absence does not make the charge
        // unreadable, and refusing on it would drop a perfectly good transaction.
        var occurredAt: Date?
        if amountIndex + 1 < lines.count,
           let candidate = dateCandidate(lines[amountIndex + 1]),
           let day = dateFormatter.date(from: candidate) {
            // The message carries a date but no time and no zone, so the parsed value lands at
            // midnight. Noon is used instead so a timezone shift cannot drag the row onto the
            // previous day — and the UI shows these rows as a date with no time at all, rather
            // than inventing a 12:00 AM the message never stated.
            occurredAt = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }

        return [ParsedAlert(
            kind: .charge,
            amountMinor: amountMinor,
            currencyCode: "USD",
            cardSuffix: account,
            merchant: cleanMerchant,
            rawVerb: "charged",
            occurredAt: occurredAt,
            parserVersion: version
        )]
    }

    static func parseFirst(_ text: String) -> ParsedAlert? { parseAll(text).first }

    // MARK: - Internals

    private struct Match {
        let index: Int
        let captures: [String]
    }

    private static func firstMatch(
        _ pattern: NSRegularExpression?,
        in lines: [String],
        from start: Int
    ) -> Match? {
        guard let pattern, start < lines.count else { return nil }
        for index in start..<lines.count {
            let line = lines[index]
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let result = pattern.firstMatch(in: line, range: range) else { continue }
            var captures: [String] = []
            for group in 1..<result.numberOfRanges {
                let r = result.range(at: group)
                captures.append(r.location == NSNotFound ? "" : (line as NSString).substring(with: r))
            }
            return Match(index: index, captures: captures)
        }
        return nil
    }

    private static func dateCandidate(_ line: String) -> String? {
        guard let pattern = datePattern else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return pattern.firstMatch(in: line, range: range) != nil ? line : nil
    }

    /// Boilerplate phrases that are never a merchant name. The line above the amount is a
    /// merchant in every real sample; this guards the case where the template changes and
    /// something else lands there.
    private static let boilerplateMarkers = [
        "american express", "account ending", "there was a large purchase",
        "dear ", "as you requested", "you can change", "you can track",
    ]

    static func cleanMerchant(_ raw: String) -> String? {
        let merchant = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "*"))

        guard !merchant.isEmpty else { return nil }
        // A merchant is never an amount, and never the account line.
        guard !merchant.hasPrefix("$") else { return nil }

        let lowered = merchant.lowercased()
        guard !boilerplateMarkers.contains(where: { lowered.contains($0) }) else { return nil }

        return merchant
    }

}
