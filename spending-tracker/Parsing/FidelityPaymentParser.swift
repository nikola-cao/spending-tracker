//
//  FidelityPaymentParser.swift
//  spending-tracker
//
//  Pure. No store, no UI, no async, no dependency on the automation.
//

import Foundation

/// Extracts a card payment from a Fidelity "a payment has been posted" SMS.
///
/// The shape, captured from the user's real phone:
///
///     Fidelity® Credit Card: A payment of $316.29 has been posted to your account ending in
///     7224 on 10/13/2026. Msg&Data rates may apply. Reply STOP to cancel.
///
/// The sibling of `AmexPaymentParser`, and the second source of the same kind. Nothing else in
/// the app had to learn about it: a payment is stored as its effect, so both balance folds sum
/// it in without a branch that knows where it came from.
///
/// **Fully literal, unlike the charge parser.** The sentence is fixed — there is no free-form
/// descriptor here — so every phrase between the figures is spelled out, and a template change
/// refuses rather than guesses. In particular the amount is anchored between `A payment of` and
/// `has been posted to your account ending in`.
///
/// **`account ending in` alone is not evidence.** It is ordinary banking English that any issuer
/// may print, and the `Fidelity® Credit Card:` preamble is required alongside it for that
/// reason — the same anchor the charge parser uses, tolerated the same way for the registered
/// mark and the mojibake a re-encoding relay produces.
///
/// **Strict by design, in the direction this project always chooses.** The charge text arrives
/// from the same sender with the same preamble, so the sentence is the only thing separating the
/// two. The registry runs the charge parser first, and that order is what settles a body carrying
/// both — it is read as the charge, and the payment in it is dropped. `FidelityPaymentParserTests`
/// asserts the refusal in both directions rather than trusting the argument.
nonisolated enum FidelityPaymentParser {

    /// Bumped whenever the sentence below changes shape. Stamped on every `ParsedAlert`, so rows
    /// parsed by an older table are identifiable and history can be re-derived after a fix.
    static let version = 1

    /// Kept as data rather than a `Regex` literal, so it can be compiled and asserted in a test
    /// and a dialect problem surfaces there rather than as a silent no-match on the phone.
    ///
    /// Pieces that are deliberate and easy to "simplify" into a bug:
    /// * `[^\s]{0,3}` after `Fidelity` tolerates the registered mark, `(R)`, and the
    ///   two-character mojibake `Â®`. Losing this anchor drops every payment, not one field.
    /// * `[0-9]` rather than `\d` throughout — ICU's `\d` matches any Unicode decimal digit, so
    ///   `\d{4}` would capture Arabic-Indic digits as a card number that can never match a card.
    /// * `[0-9]{4}` exactly, because this programme prints four digits — the charge parser reads
    ///   its card the same width. A five-digit print would therefore refuse the payment rather
    ///   than record it against a card number that is not the one on file. Amex's email is the
    ///   one that prints five, and `AmexPaymentParser` is where that width lives.
    /// * `\$\s*` tolerates a space after the symbol; `\$[0-9]` hard-adjacency loses the whole
    ///   alert over one inserted space.
    /// * The date is **optional**. It costs the row nothing but its date when absent, and
    ///   refusing on it would drop a perfectly good payment — the same trade `AmexPaymentParser`
    ///   makes for its `Processed on:` line.
    /// * The date group accepts **any token** after `on`, not merely a date-shaped one, and is
    ///   validated afterwards by the strict formatter below. That is what makes the rule this
    ///   parser documents actually hold: a date that is absent, out of range, or garbled costs
    ///   the row its date and not the row. A date-shaped-only group would have taken the amount
    ///   and the card down with it — a payment refused over a corrupted day is a lost row, and
    ///   the amount it would have carried was never in doubt.
    /// * The terminator is a period, the alert's own trailer, or the end of the string. The
    ///   trailer alternative is the charge parser's own tolerance for the same relay damage — a
    ///   body whose sentence period was replaced by a newline still names `Msg&Data` — and it is
    ///   here for parity rather than for recall's own sake. A body that merely carries on with
    ///   prose is refused, as it is there.
    static let pattern = #"Fidelity\s*[^\s]{0,3}\s*Credit\s+Card:\s*A\s+payment\s+of\s+\$\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{2})?)\s+has\s+been\s+posted\s+to\s+your\s+account\s+ending\s+in\s+(?<last4>[0-9]{4})(?:\s+on\s+(?<date>[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}|[^\s]{1,16}))?(?:\s*\.|\s+(?=(?:Msg\s*&\s*(?:amp;)?\s*Dat|Reply\s+STOP))|\s*$)"#

    /// `nil` only if the pattern fails to compile, which a test asserts cannot happen.
    static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: pattern,
        // Deliberately NOT `.anchorsMatchLines`: `\s*$` is the unterminated-alert fallback, and
        // a multiline `$` would let it fire at an embedded newline instead of at the end.
        options: [.caseInsensitive]
    )

    /// `10/13/2026` — the US month-first form the issuer prints.
    ///
    /// **`isLenient = false` is load-bearing.** A lenient formatter accepts `13/10/2026` and
    /// silently reads it as day 13 of a thirteenth month — rolled forward into January — and
    /// accepts `02/30/2026` as March 2nd. Either one puts a plausible-looking wrong date on a
    /// row. Strict, a date outside the shape is simply unreadable, and the row falls back to
    /// arrival, which is the honest answer.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MM/dd/yyyy"
        formatter.isLenient = false
        return formatter
    }()

    /// The merchant this records under. A payment has no merchant — it is the user's own money
    /// moving to settle a card — so the row is named for what it is, and for which issuer's card
    /// it settled, which is also how a Fidelity payment is told apart from an Amex one in a feed
    /// that shows both under the same `Payment` subtitle.
    static let merchant = "Fidelity payment"

    /// Every payment in the string. Empty when nothing matches.
    ///
    /// All matches rather than the first, because bodies arrive concatenated with no separator —
    /// the same reason the charge parser takes them all.
    static func parseAll(_ raw: String) -> [ParsedAlert] {
        guard let regex else { return [] }
        // The charge parser's normalisation, shared rather than copied: same sender, same relay,
        // same invisible characters and the same flattened newlines. A second copy is a second
        // place for the two to disagree about a body both of them are asked about.
        let text = FidelityAlertParser.normalize(raw) as NSString
        let range = NSRange(location: 0, length: text.length)
        return regex.matches(in: text as String, range: range).compactMap { alert(from: $0, in: text) }
    }

    /// The first payment in the string, if any. Convenience for the single-message case.
    static func parseFirst(_ raw: String) -> ParsedAlert? { parseAll(raw).first }

    // MARK: - Internals

    private static func alert(from match: NSTextCheckingResult, in text: NSString) -> ParsedAlert? {
        guard
            let amountText = group("amount", match, text),
            let last4 = group("last4", match, text),
            let amountMinor = Money.minorUnits(from: amountText)
        else { return nil }

        return ParsedAlert(
            kind: .payment,
            // Stored as its effect. The figure Fidelity prints is what was paid; what the ledger
            // needs is what it took away, which is why a payment needs no subtraction anywhere
            // downstream — both balance folds simply add it, and it comes off each by being
            // negative. See `ParsedAlert.affectsBank` and `affectsCard`.
            amountMinor: -amountMinor,
            currencyCode: "USD",
            cardSuffix: last4,
            merchant: merchant,
            rawVerb: "paid",
            occurredAt: postedAt(group("date", match, text)),
            parserVersion: version
        )
    }

    private static func group(
        _ name: String,
        _ match: NSTextCheckingResult,
        _ text: NSString
    ) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, range.length > 0 else { return nil }
        return text.substring(with: range)
    }

    /// The day the payment posted, at noon — the convention every date-only source here uses,
    /// and the reason the UI shows these rows as a date with no clock time at all.
    ///
    /// Nil for a date the strict formatter refuses, which costs the row its date but not the row.
    private static func postedAt(_ text: String?) -> Date? {
        guard let text, let day = dateFormatter.date(from: text) else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }
}
