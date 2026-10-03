//
//  VenmoAlertParser.swift
//  spending-tracker
//
//  Money in and out of Venmo, from the notification emails.
//

import Foundation

/// Reads a Venmo payment notification.
///
/// ## The trap this parser is built around
///
/// Every one of these emails states the payment **both ways round**. The visible body says what
/// happened to the user — `Sarvesh Gade paid you` — and a hidden `display:none` preheader says
/// it from the other party's side: `You paid Sarvesh Gade $28.00`. It exists to fill the inbox
/// preview line, and in a *sent* payment it reads the other way round again
/// (`Patrick guo paid you $386.70`).
///
/// So neither phrase can be trusted alone, and `HTMLText` does not drop hidden elements — its
/// job is to recover the text that is in the document, and this text is in the document. A
/// parser keyed on `You paid` would read every payment received as money sent. That is a sign
/// inversion, which is the worst failure available here: the row still looks entirely plausible,
/// and the bank moves the wrong way.
///
/// Direction therefore comes from the two lines that appear exactly once and in only one kind
/// of email — `Money credited to your Venmo account.` for money in, and the `Payment Method`
/// field for money out. Both are template text rather than prose, and neither is duplicated. A
/// body with neither is refused rather than guessed at.
///
/// ## What it produces
///
/// A **deposit**, positive when money arrived and negative when it left, which is what the
/// ledger means by a deposit and what the bank balance folds over. See `JournalInstruction` and
/// `LedgerStore.bankBalance`.
nonisolated enum VenmoAlertParser {

    static let version = 1

    /// The envelope. Venmo's own address, in the forwarded header the automation hands over.
    ///
    /// Required rather than inferred, because `Payment Method` is generic enough to turn up in
    /// an order confirmation and the Amex automation has already shown that these filters
    /// capture more than they are meant to.
    ///
    /// It is one of **two** envelopes, and the second exists because of how the body gets here.
    /// The address arrives as `&lt;venmo@venmo.com&gt;` and survives `HTMLText` — entities are
    /// decoded after tags are stripped — but anything that looks like a tag is removed, so a
    /// body flattened twice loses it. `creditedMarker` cannot be mangled that way and no other
    /// sender writes it, so a received payment is still recognised without the header. A *sent*
    /// one has only this address to identify it, which is the price of not treating the very
    /// generic `Payment Method` as an envelope on its own.
    private static let senderMarker = "venmo@venmo.com"

    /// Money arriving. Only a credited payment says this.
    private static let creditedMarker = "Money credited to your Venmo account."

    /// Money leaving. Only a sent payment has a funding source to name.
    private static let sentMarker = "Payment Method"

    /// Either of these means the body is a Venmo payment at all. See `senderMarker`.
    private static let envelopeMarkers = [senderMarker, creditedMarker]

    /// Where the two visible phrasings are read from. Anchored at both ends on purpose: the
    /// hidden preheader is the same sentence with the amount appended, so requiring the line to
    /// *end* after the phrase is what keeps the two apart.
    private static let receivedPhrase = try? NSRegularExpression(pattern: #"^(.+?) paid you$"#)
    private static let sentPhrase = try? NSRegularExpression(pattern: #"^You paid (.+)$"#)

    /// The note and the invoice amount sit between these. `See transaction` bounds the note.
    private static let noteTerminator = "See transaction"

    /// How many lines past the amount the note may run. Bounded so a template change that drops
    /// `See transaction` cannot turn the rest of the email into a merchant name.
    private static let maximumNoteLines = 3

    private static let dateFieldLabel = "Date"

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM dd, yyyy"
        return formatter
    }()

    private enum Direction {
        case received
        case sent
    }

    // MARK: - Reading

    static func parseAll(_ text: String) -> [ParsedAlert] {
        guard envelopeMarkers.contains(where: text.contains) else { return [] }

        let direction: Direction
        if text.contains(creditedMarker) {
            direction = .received
        } else if text.contains(sentMarker) {
            direction = .sent
        } else {
            // A Venmo email from a template neither marker fits. Refusing costs a missing row;
            // guessing costs the wrong sign, which is a wrong number.
            return []
        }

        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard let phraseIndex = lines.firstIndex(where: {
            capturedName(in: $0, direction: direction) != nil
        }), let name = capturedName(in: lines[phraseIndex], direction: direction) else { return [] }

        let afterPhrase = Array(lines[(phraseIndex + 1)...])
        let fragments = afterPhrase.prefix(while: isAmountFragment)
        guard let magnitude = amount(from: Array(fragments)) else { return [] }

        let note = note(from: Array(afterPhrase.dropFirst(fragments.count)))
        let occurredAt = transactionDate(in: lines)

        return [
            ParsedAlert(
                kind: .deposit,
                amountMinor: direction == .received ? magnitude : -magnitude,
                currencyCode: "USD",
                // A deposit has no card, and the journal format refuses one on a deposit line.
                cardSuffix: "",
                merchant: merchant(name: name, note: note),
                rawVerb: direction == .received ? "paid you" : "you paid",
                occurredAt: occurredAt,
                parserVersion: version
            )
        ]
    }

    static func parseFirst(_ text: String) -> ParsedAlert? { parseAll(text).first }

    // MARK: - Pieces

    /// `Venmo: Sarvesh Gade - Kimchi red`, or without the dash when the payment carried no note.
    ///
    /// Built here rather than at the call site so the one owner for the shape is the parser,
    /// the same arrangement the manual line has.
    private static func merchant(name: String, note: String) -> String {
        note.isEmpty ? "Venmo: \(name)" : "Venmo: \(name) - \(note)"
    }

    private static func capturedName(in line: String, direction: Direction) -> String? {
        let pattern = direction == .received ? receivedPhrase : sentPhrase
        guard let pattern else { return nil }

        let range = NSRange(location: 0, length: (line as NSString).length)
        guard let match = pattern.firstMatch(in: line, range: range), match.numberOfRanges > 1,
              let nameRange = Range(match.range(at: 1), in: line)
        else { return nil }

        let name = String(line[nameRange]).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The amount, reassembled from the line-per-element markup.
    ///
    /// Venmo renders the figure as four sibling elements — `$`, `28`, `.`, `00` — and every one
    /// is a `<div>`, which `HTMLText` turns into its own line. The decimal point sits in a
    /// `display:none` span, so it survives into the text and is the only reason the digits can
    /// be put back together at all.
    ///
    /// Joining with no separator is what makes `$` `28` `.` `00` read as `$28.00`. That same
    /// join would turn `$` `28` `00` — a template with the point gone — into `$2800`: a
    /// hundredfold error stated with total confidence. So a run holding more than one group of
    /// digits and no point in it is **refused**, because the two readings are genuinely
    /// different amounts and nothing in the text chooses between them.
    private static func amount(from fragments: [String]) -> Int? {
        // The `$` is the anchor that says a run has started, and it is dropped before the rest
        // is read: `Money.minorUnits` is strict and refuses a currency symbol, which is right —
        // it exists to read an issuer's own figure, and a stray symbol there would mean the
        // template changed underneath it.
        guard fragments.first == "$" else { return nil }
        let figure = Array(fragments.dropFirst())

        let digitGroups = figure.filter { $0.contains(where: \.isNumber) }
        if digitGroups.count > 1, !figure.contains(".") { return nil }

        return Money.minorUnits(from: figure.joined())
    }

    /// A line that is nothing but currency punctuation and digits — one piece of the figure.
    ///
    /// A bare `.` counts, and has to: the decimal point is a `<span>` of its own between two
    /// `<div>`s, so it lands on a line by itself. Requiring a digit on every fragment stopped
    /// the run dead at the point and left `$28`, which is not an amount.
    ///
    /// Being permissive here is safe because the run cannot begin anywhere except on a `$`
    /// line — see `amount(from:)` — and the joined result still has to survive the strict
    /// currency parser. Length-bounded so a line of prose cannot be mistaken for a fragment.
    private static func isAmountFragment(_ line: String) -> Bool {
        guard !line.isEmpty, line.count <= 12 else { return false }
        return line.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "$" || $0 == "." || $0 == ",") }
    }

    /// The free text the sender attached, sitting between the figure and `See transaction`.
    private static func note(from lines: [String]) -> String {
        var parts: [String] = []
        for line in lines.prefix(maximumNoteLines) {
            if line.hasPrefix(noteTerminator) { break }
            parts.append(line)
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// The transaction's own date field, not the forwarded header's.
    ///
    /// The header carries `Date: Fri, Oct 2, 2026 at 9:01 PM`, which is when the *email* was
    /// sent and is a different line shape. `Date` on its own is the transaction field, and the
    /// value is a date with no time — so it lands at noon, the same convention every other
    /// date-only source here uses.
    private static func transactionDate(in lines: [String]) -> Date? {
        guard let label = lines.firstIndex(of: dateFieldLabel),
              lines.index(after: label) < lines.endIndex
        else { return nil }

        let value = lines[lines.index(after: label)]
        guard let day = dateFormatter.date(from: value) else { return nil }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }
}
