//
//  FidelityAlertParser.swift
//  spending-tracker
//
//  Pure. No store, no UI, no async, no dependency on the automation.
//

import Foundation

/// Extracts structured fields from a Fidelity card alert body.
///
/// The shape being parsed, captured from the user's real phone:
///
///     Fidelity® Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel.
///
/// Design notes that are load-bearing:
///
/// * **Anchored, not split.** Extraction finds fixed phrases and captures what lies between
///   them. Splitting on `" at "` or `" on "` looks simpler and is wrong: merchant
///   descriptors contain both (`AT&T`, `SHOP ON MAIN`), and contain periods
///   (`AMAZON.COM*MK1A2B3C4`) and asterisks (`PICKUP* TRIAL OVER`).
///
/// * **Anchor on the trailer, not the first period.** A lazy capture terminated by `\.`
///   stops inside `AMAZON.COM` and silently yields the merchant `"AMAZON"`.
///
/// * **All matches, not the first.** Bodies can arrive concatenated with no separator.
///
/// * **Fail visibly, never silently.** Where the shape is ambiguous — an amount with
///   non-standard comma grouping, a descriptor that is really boilerplate — the parser
///   rejects the match rather than guessing. A rejected alert is absent from the parsed
///   list and therefore visible as "did not parse"; a wrong amount is not visible at all.
nonisolated enum FidelityAlertParser {

    /// Bumped to 2 after an adversarial corpus pass. Stamped on every `ParsedAlert` so rows
    /// parsed by an older table are identifiable, and history can be re-derived after a fix.
    static let version = 2

    /// Kept as data rather than a `Regex` literal so it can be compiled and asserted in a
    /// test, and so a dialect problem surfaces as a failing test rather than a silent
    /// no-match in production.
    ///
    /// Pieces that are deliberate and easy to "simplify" into a bug:
    /// * `[^\s]{0,3}` after `Fidelity` tolerates the registered mark, `(R)`, and the
    ///   two-character mojibake `Â®` a re-encoding relay produces. Losing this anchor drops
    ///   *every* charge, not one field.
    /// * `[0-9]` rather than `\d` throughout — ICU's `\d` matches any Unicode decimal digit,
    ///   so `\d{4}` would happily capture Arabic-Indic digits as the card number.
    /// * `\$\s*` tolerates a space after the symbol; `\$[0-9]` hard-adjacency loses the
    ///   whole alert over one inserted space.
    /// * `(?:(?!Fidelity\s*[^\s]{0,3}\s*Credit\s+Card:).){1,200}?` is a tempered capture: it
    ///   refuses to cross into the start of another alert. An unterminated alert's lazy
    ///   capture would otherwise run forward and swallow the *next* alert whole. The
    ///   lookahead must be the FULL preamble, not the bare word `Fidelity` — the first
    ///   version blocked on the word alone and therefore refused to cross a trailing
    ///   `Fidelity.com/alerts` footer, losing the alert entirely.
    static let pattern = #"Fidelity\s*[^\s]{0,3}\s*Credit\s+Card:\s*Your\s+card\s+ending\s+in\s+(?<last4>[0-9]{4})\s+was\s+(?<verb>[A-Za-z]+)\s+\$\s*(?<amount>[0-9][0-9,]*(?:\.[0-9]{2})?)\s+at\s+(?<merchant>(?:(?!Fidelity\s*[^\s]{0,3}\s*Credit\s+Card:).){1,200}?)(?:\.\s*(?:Msg\s*&\s*(?:amp;)?\s*Data|Reply\s+STOP)|\.?\s*$)"#

    /// `nil` only if the pattern fails to compile, which a test asserts cannot happen.
    static let regex: NSRegularExpression? = try? NSRegularExpression(
        pattern: pattern,
        // Deliberately NOT `.anchorsMatchLines`: that would let `$` match at an embedded
        // newline and terminate the lazy merchant capture early.
        options: [.caseInsensitive]
    )

    /// Every alert in the string. Empty when nothing matches.
    static func parseAll(_ raw: String) -> [ParsedAlert] {
        guard let regex else { return [] }
        let text = normalize(raw) as NSString
        let range = NSRange(location: 0, length: text.length)
        return regex.matches(in: text as String, range: range).compactMap { alert(from: $0, in: text) }
    }

    /// The first alert in the string, if any. Convenience for the single-message case.
    static func parseFirst(_ raw: String) -> ParsedAlert? { parseAll(raw).first }

    // MARK: - Normalisation

    /// Removes characters that are invisible in every UI but break token boundaries, and
    /// flattens newlines.
    ///
    /// Newlines matter because `.` cannot cross one and `$` is deliberately not
    /// multiline-anchored, so a newline anywhere inside an alert makes every terminator
    /// unreachable and the whole match attempt is abandoned — a silent total loss rather
    /// than a corrupted field. No newline carries meaning in a one-line alert body.
    static func normalize(_ raw: String) -> String {
        var text = raw
        for invisible in ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}", "\u{034F}", "\u{2060}"] {
            text = text.replacingOccurrences(of: invisible, with: "")
        }
        text = text.replacingOccurrences(of: "\r\n", with: " ")
        text = text.replacingOccurrences(of: "\n", with: " ")
        text = text.replacingOccurrences(of: "\r", with: " ")
        return text
    }

    // MARK: - Internals

    private static func alert(from match: NSTextCheckingResult, in text: NSString) -> ParsedAlert? {
        guard
            let last4 = group("last4", match, text),
            let verb = group("verb", match, text),
            let amountText = group("amount", match, text),
            let merchantText = group("merchant", match, text),
            let amountMinor = Money.minorUnits(from: amountText),
            let merchant = cleanMerchant(merchantText)
        else { return nil }

        let verbLower = verb.lowercased()
        return ParsedAlert(
            kind: verbLower == "charged" ? .charge : .unrecognizedVerb,
            amountMinor: amountMinor,
            currencyCode: "USD",
            cardSuffix: last4,
            merchant: merchant,
            rawVerb: verbLower,
            // The Fidelity SMS carries no timestamp of its own, so the ledger falls back to
            // the alert's arrival time.
            occurredAt: nil,
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

    /// Boilerplate fragments that must never end up inside a descriptor. Checked by the
    /// cleaner because the pattern's trailer alternative only recognises the exact wording:
    /// an HTML-escaped `&amp;` or a segment truncated to `Msg&Dat` slips past it, and the
    /// lazy capture then absorbs the boilerplate into the merchant.
    private static let boilerplateMarkers = [
        "msg&data", "msg&amp;data", "msg&dat", "msg & data", "reply stop",
    ]

    /// Turns a raw capture into a descriptor, or rejects it.
    ///
    /// Returning `nil` discards the match, so the alert shows up as unparsed rather than as
    /// a row with a plausible-looking wrong merchant. That trade is deliberate: an
    /// unparsed alert is visible in the journal, a wrong merchant is not.
    static func cleanMerchant(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // Quoted-reply markers from a forwarded or copied message.
        while text.hasPrefix(">") || text.hasPrefix("|") {
            text.removeFirst()
            text = text.trimmingCharacters(in: .whitespaces)
        }

        // Cut at the earliest boilerplate fragment.
        let lowered = text.lowercased()
        var cut = text.count
        for marker in boilerplateMarkers {
            if let found = lowered.range(of: marker) {
                cut = min(cut, lowered.distance(from: lowered.startIndex, to: found.lowerBound))
            }
        }
        if cut < text.count {
            text = String(text.prefix(cut))
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // A card descriptor does not contain ". ". If one survives, it marks the start of a
        // trailing sentence the no-trailer fallback swallowed — a URL footer, a support
        // number, or a smishing call-back lure.
        if let sentence = text.range(of: ". ") {
            text = String(text[..<sentence.lowerBound])
        }

        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // Truncation markers the end-of-string fallback leaves attached.
        while text.hasSuffix(".") || text.hasSuffix("…") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }

        // A descriptor never begins with sentence punctuation. If it does, the capture
        // started inside the boilerplate — this is a phantom, not a transaction. This is
        // the case that defeats the old "merchant must be non-empty" check, because
        // ". Msg&Data rates may apply" is non-empty.
        guard let first = text.first, !". ,;:!?".contains(first) else { return nil }

        return text
    }
}
