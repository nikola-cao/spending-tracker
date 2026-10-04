//
//  AmexPaymentParser.swift
//  spending-tracker
//
//  Pure. No store, no UI, no async, no dependency on the automation.
//

import Foundation

/// Extracts a card payment from an American Express "we've received your payment" email.
///
/// The shape, captured from the user's real inbox (already-flattened text, as the Shortcut
/// hands it over):
///
///     Thanks for your payment received on Sep 30, 2026
///
///     NIKOLA CAO
///     Account Ending: 21006
///
///     Thank you for your payment
///
///     We received your payment.
///     You're all set. You can view your updated balances online.
///
///     Don't see the deduction in your bank account? ...
///     Payment amount:
///     $1,044.97
///     Processed on:
///     Sep 30, 2026
///     Helpful Links
///
/// **Two labels, not one.** The figure sits under `Payment amount:` and the date under
/// `Processed on:`, so both are read from the line *after* their label rather than by shape.
/// That matters because this email also opens with a date — `received on Sep 30, 2026` — and
/// scanning for anything date-shaped would happily take that one instead.
///
/// **Strict by design.** The Email automation captures more than it is asked to, and the Amex
/// purchase alert — which is a completely different transaction — arrives from the same sender
/// with the same account line and its own dollar figure. So this refuses anything without the
/// body sentence *and* the amount label, rather than finding a number and hoping. The registry
/// also runs the large-purchase parser first, so an alert can never be read as a payment.
nonisolated enum AmexPaymentParser {

    static let version = 1

    /// Amex's own sentence, and the one a merchant receipt or a purchase alert will never
    /// contain. Lowercased for a case-insensitive comparison.
    static let envelope = "we received your payment"

    /// The field the figure sits under. Required as well as the sentence, so a template change
    /// to either one refuses rather than guesses.
    private static let amountLabel = "payment amount:"

    private static let dateLabel = "processed on:"

    /// Amex prints five digits (`Account Ending: 21006`). Read exactly as printed and never
    /// truncated — see `ParsedAlert.cardSuffix`.
    private static let accountPattern = try? NSRegularExpression(
        pattern: #"^account ending:\s*([0-9]{4,6})$"#, options: [.caseInsensitive])

    /// A line that is nothing but an amount: `$1,044.97`. Requiring the whole line is what stops
    /// a stray figure inside the prose above it from being picked up — that paragraph mentions a
    /// bank account, and the boilerplate further down cites a phone number.
    private static let amountPattern = try? NSRegularExpression(
        pattern: #"^\$([0-9][0-9,]*\.[0-9]{2})$"#)

    /// `Sep 30, 2026`. No weekday, unlike the purchase alert's `Tue, Sep 22, 2026`.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    /// The merchant this records under. A payment has no merchant — it is the user's own money
    /// moving to settle a card — so the row is named for what it is, and the card it settled
    /// shows in the row's subtitle alongside it.
    static let merchant = "Amex payment"

    /// The payment in the text, or empty when this is not an Amex payment confirmation.
    static func parseAll(_ text: String) -> [ParsedAlert] {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.contains(where: { $0.lowercased().contains(envelope) }),
              let labelIndex = lines.firstIndex(where: {
                  $0.lowercased() == amountLabel
              }),
              labelIndex + 1 < lines.count,
              let amountText = amount(from: lines[labelIndex + 1]),
              // Stored as its effect. The figure Amex prints is what was paid; what the ledger
              // needs is what it took away, which is why a payment needs no subtraction
              // anywhere downstream — see `ParsedAlert.affectsSpend`.
              let amountMinor = Money.minorUnits(from: amountText)
        else { return [] }

        return [ParsedAlert(
            kind: .payment,
            amountMinor: -amountMinor,
            currencyCode: "USD",
            cardSuffix: account(in: lines) ?? "",
            merchant: merchant,
            rawVerb: "paid",
            // Optional, like the purchase alert's: losing it costs the row its date but not the
            // row, and refusing on it would drop a perfectly good transaction.
            occurredAt: processedAt(in: lines, after: labelIndex),
            parserVersion: version
        )]
    }

    static func parseFirst(_ text: String) -> ParsedAlert? { parseAll(text).first }

    // MARK: - Internals

    private static func account(in lines: [String]) -> String? {
        guard let pattern = accountPattern else { return nil }
        for line in lines {
            let range = NSRange(location: 0, length: (line as NSString).length)
            guard let match = pattern.firstMatch(in: line, range: range),
                  match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: line)
            else { continue }
            return String(line[captured])
        }
        return nil
    }

    private static func amount(from line: String) -> String? {
        guard let pattern = amountPattern else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = pattern.firstMatch(in: line, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: line)
        else { return nil }
        return String(line[captured])
    }

    /// The day under `Processed on:`.
    ///
    /// Searched from the amount label onwards, so the `received on Sep 30, 2026` in the opening
    /// sentence — which is the same day here but need not be — cannot be mistaken for it.
    private static func processedAt(in lines: [String], after labelIndex: Int) -> Date? {
        guard let dateIndex = lines[(labelIndex + 1)...].firstIndex(where: {
            $0.lowercased() == dateLabel
        }), dateIndex + 1 < lines.count
        else { return nil }

        guard let day = dateFormatter.date(from: lines[dateIndex + 1]) else { return nil }
        // A date with no time, so noon — the convention every date-only source here uses, and
        // the reason the UI shows these rows as a date with no clock time at all.
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }
}
