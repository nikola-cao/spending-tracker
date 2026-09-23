//
//  HTMLText.swift
//  spending-tracker
//
//  Recover readable text from an HTML email body.
//

import Foundation

/// Flattens an HTML email body to line-structured text.
///
/// Amex alerts arrive as a full HTML document — a Shortcut reading the Mail message hands over
/// markup, not prose. The markup has no usable semantic hooks either: the amount and the
/// merchant sit in bare `<p>` elements distinguished only by inline CSS, and classes like
/// `body-1` are shared with the boilerplate. So structural HTML parsing has nothing to anchor
/// on, and the only sound approach is to recover the text and parse that.
///
/// Text passes through unchanged when there is no markup, so this is safe to run on the
/// plain-text SMS bodies too and can be applied unconditionally.
nonisolated enum HTMLText {

    /// Block-level boundaries become newlines so that adjacent elements do not fuse into one
    /// line. `<p>NIKOLA CAO</p><p>Account Ending: 21008</p>` must not become
    /// `NIKOLA CAOAccount Ending: 21008`.
    private static let blockBreak = try? NSRegularExpression(
        pattern: #"<\s*/?\s*(p|div|tr|td|table|tbody|thead|li|ul|ol|h[1-6]|br|hr|center|blockquote)\b[^>]*>"#,
        options: [.caseInsensitive]
    )

    private static let comment = try? NSRegularExpression(pattern: #"<!--.*?-->"#, options: [.dotMatchesLineSeparators])
    private static let drop = try? NSRegularExpression(
        pattern: #"<\s*(script|style|head|title)\b[^>]*>.*?<\s*/\s*\1\s*>"#,
        options: [.caseInsensitive, .dotMatchesLineSeparators]
    )
    private static let tag = try? NSRegularExpression(pattern: #"<[^>]*>"#, options: [.dotMatchesLineSeparators])

    /// Characters email senders insert to defeat preview-text scrapers and to pad layout.
    /// They are invisible in every UI and will silently break a token match, so they are
    /// removed rather than trusted. Amex's own templates use U+034F liberally.
    ///
    /// Removed by **scalar**, not by `Character`. `U+034F` is a combining mark, and a Swift
    /// `Character` is a grapheme cluster — so `"8\u{034F}"` is a single `Character` and a
    /// `filter` over characters never sees the mark as its own element. That version silently
    /// left the mark in place, where it then broke the account-number match, because
    /// `NSRegularExpression` works on UTF-16 code units and the trailing scalar pushed `$`
    /// out of reach. `U+200B` is not combining, so it was stripped correctly the whole time
    /// and hid the bug.
    private static let invisibleScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}",
        "\u{00AD}", "\u{034F}", "\u{180E}", "\u{115F}", "\u{1160}",
    ]

    /// The body as line-structured text. Never throws: a body that cannot be decoded is
    /// returned as-is rather than dropped, because the caller's job is to notice unreadable
    /// input, not to make it disappear.
    static func extract(from raw: String) -> String {
        var text = raw

        if let drop {
            text = drop.stringByReplacingMatches(in: text, range: full(text), withTemplate: " ")
        }
        if let comment {
            text = comment.stringByReplacingMatches(in: text, range: full(text), withTemplate: " ")
        }
        if let blockBreak {
            text = blockBreak.stringByReplacingMatches(in: text, range: full(text), withTemplate: "\n")
        }
        if let tag {
            text = tag.stringByReplacingMatches(in: text, range: full(text), withTemplate: " ")
        }

        text = decodeEntities(in: text)
        text = removingInvisibles(from: text)

        // Collapse runs of horizontal whitespace, then runs of blank lines, so the result is
        // one line per logical element.
        //
        // `[^\S\n]` is "whitespace except a newline", which is both shorter and more correct
        // than enumerating space characters: the templates use U+2007 (figure space) and
        // friends, and ICU's whitespace class already covers every Unicode space separator.
        // Newlines are excluded because they are the line structure this whole approach rests
        // on — collapsing them would fuse adjacent elements back together.
        text = text.replacingOccurrences(
            of: #"[^\S\n]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\n[^\S\n]*"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\n{2,}"#, with: "\n", options: .regularExpression)

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Internals

    private static func full(_ text: String) -> NSRange {
        NSRange(location: 0, length: (text as NSString).length)
    }

    /// Strips invisibles at the scalar level — see the note on `invisibleScalars` for why a
    /// `Character`-based filter is silently wrong for combining marks.
    private static func removingInvisibles(from text: String) -> String {
        guard text.unicodeScalars.contains(where: { invisibleScalars.contains($0) }) else {
            return text
        }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !invisibleScalars.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Named entities worth carrying. Taken from what Amex's and merchants' templates actually
    /// emit rather than the full HTML5 table: `&shy;` alone accounts for a hundred occurrences
    /// per email, because senders use soft hyphens as invisible layout padding.
    ///
    /// `&amp;` is deliberately NOT special-cased as "decode last" — see `decodeEntities`.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": " ", "shy": "\u{00AD}",
        "rsquo": "\u{2019}", "lsquo": "\u{2018}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "hellip": "\u{2026}",
        "middot": "\u{00B7}", "copy": "\u{00A9}", "reg": "\u{00AE}",
        "trade": "\u{2122}", "deg": "\u{00B0}", "bull": "\u{2022}",
    ]

    /// Decodes entities in a **single left-to-right pass**.
    ///
    /// A sequence of `replacingOccurrences` passes is subtly wrong as well as slow: the
    /// replacements run in dictionary order, which Swift does not define, so whether
    /// `&amp;shy;` decodes once or twice would vary between runs. Scanning once and never
    /// re-examining what was emitted removes that class of bug outright — and it is one pass
    /// over the body instead of twenty.
    ///
    /// An unrecognised entity is left exactly as written, so it stays visible rather than
    /// silently becoming something else.
    private static func decodeEntities(in text: String) -> String {
        guard text.contains("&") else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "&" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            // An entity is short; anything longer is a stray ampersand in prose.
            let window = text[index...].prefix(12)
            guard let semicolon = window.firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let entity = String(text[index...semicolon])
            if let decoded = decode(entity) {
                result.append(decoded)
            } else {
                result.append(contentsOf: entity)
            }
            index = text.index(after: semicolon)
        }
        return result
    }

    /// `"&amp;"` → `"&"`, `"&#847;"` → the scalar, `"&#x27;"` → the scalar, anything else nil.
    private static func decode(_ entity: String) -> String? {
        guard entity.count >= 3, entity.hasPrefix("&"), entity.hasSuffix(";") else { return nil }
        let body = entity.dropFirst().dropLast()

        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let isHex = digits.hasPrefix("x") || digits.hasPrefix("X")
            let number = isHex ? digits.dropFirst() : digits
            guard let value = UInt32(number, radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }

        return namedEntities[body.lowercased()]
    }
}
