//
//  AlertCorpus.swift
//  spending-trackerTests
//
//  The regression corpus. Extend it with every real message observed.
//

import Foundation
@testable import spending_tracker

/// One raw body and exactly what the parser must make of it.
///
/// `expected` is an array because a single body can legitimately contain more than one
/// alert — two messages concatenated with no separator, which was observed in the user's
/// own paste. An empty array means "must not parse".
struct AlertFixture: Sendable {
    let name: String
    let input: String
    let expected: [ParsedAlert]
}

// MARK: - Builders

private func charge(
    _ amountMinor: Int,
    _ merchant: String,
    last4: String = "7224",
    verb: String = "charged"
) -> ParsedAlert {
    ParsedAlert(
        kind: verb == "charged" ? .charge : .unrecognizedVerb,
        amountMinor: amountMinor,
        currencyCode: "USD",
        cardSuffix: last4,
        merchant: merchant,
        rawVerb: verb,
        occurredAt: nil,          // the Fidelity SMS carries no timestamp of its own
        parserVersion: FidelityAlertParser.version
    )
}

private func fixture(
    _ name: String,
    _ input: String,
    _ expected: [ParsedAlert]
) -> AlertFixture {
    AlertFixture(name: name, input: input, expected: expected)
}

/// The trailer every real message carries. Its exact wording is the parse anchor.
private let trailer = " Msg&Data rates may apply. Reply STOP to cancel."

private func realAlert(_ amount: String, _ merchant: String, last4: String = "7224") -> String {
    "Fidelity\u{00AE} Credit Card: Your card ending in \(last4) was charged $\(amount) at \(merchant).\(trailer)"
}

// MARK: - The corpus

enum AlertCorpus {

    static let all: [AlertFixture] = realMessages + merchantEdgeCases + formatVariants + negativeCases

    /// Captured verbatim from the user's phone. These are the ground truth; no public source
    /// contains a real Fidelity purchase alert.
    static let realMessages: [AlertFixture] = [
        fixture("real: BREEZE",
                realAlert("2.50", "BREEZE*00HS5MV"),
                [charge(250, "BREEZE*00HS5MV")]),
        fixture("real: truncated merchant",
                realAlert("5.30", "DEEPSEERWEA"),
                [charge(530, "DEEPSEERWEA")]),
        fixture("real: asterisk prefix",
                realAlert("31.79", "PICKUP* TRIAL OVER"),
                [charge(3179, "PICKUP* TRIAL OVER")]),
        fixture("real: truncated with capital",
                realAlert("36.00", "Georgia Tech Parking S"),
                [charge(3600, "Georgia Tech Parking S")]),
        fixture("real: parentheses in merchant",
                realAlert("73.00", "CENTRAL ROCK MID (ATL)"),
                [charge(7300, "CENTRAL ROCK MID (ATL)")]),
    ]

    /// The cases that break a naive parser. Each one is a shape a real issuer descriptor
    /// genuinely takes.
    static let merchantEdgeCases: [AlertFixture] = [
        // A lazy capture terminated by the first period yields the merchant "AMAZON".
        fixture("merchant contains a period",
                realAlert("118.43", "AMAZON.COM*MK1A2B3C4"),
                [charge(11843, "AMAZON.COM*MK1A2B3C4")]),

        // Breaks any parser that splits on " at ". Also exercises a thousands separator.
        fixture("merchant contains an ampersand + thousands separator",
                realAlert("1,204.99", "AT&T*WIRELESS PMT"),
                [charge(120499, "AT&T*WIRELESS PMT")]),

        fixture("merchant containing ' on '",
                realAlert("42.00", "SHOP ON MAIN"),
                [charge(4200, "SHOP ON MAIN")]),

        fixture("merchant with a trailing store number",
                realAlert("17.50", "WHOLE FOODS MKT #12"),
                [charge(1750, "WHOLE FOODS MKT #12")]),

        fixture("merchant with a hyphen",
                realAlert("4.00", "CHICK-FIL-A"),
                [charge(400, "CHICK-FIL-A")]),

        // The card number must be read, not assumed.
        fixture("a different card",
                realAlert("5.00", "SOME MERCHANT", last4: "4321"),
                [charge(500, "SOME MERCHANT", last4: "4321")]),
    ]

    /// Carrier mangling and message-shape variation.
    static let formatVariants: [AlertFixture] = [
        // Boilerplate stripped, no trailing period.
        fixture("boilerplate stripped, no trailing period",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $9.99 at NETFLIX.COM",
                [charge(999, "NETFLIX.COM")]),

        // Boilerplate stripped, trailing period present.
        fixture("boilerplate stripped, trailing period",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $9.99 at NETFLIX.COM.",
                [charge(999, "NETFLIX.COM")]),

        // Transaction alerts are long; this is the segment-split case. The body is cut
        // mid-merchant with no period and no trailer.
        fixture("truncated mid-merchant",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $22.10 at WHOLE FOODS MKT",
                [charge(2210, "WHOLE FOODS MKT")]),

        // The registered sign transcoded, and absent entirely.
        fixture("registered sign transcoded as (R)",
                "Fidelity(R) Credit Card: Your card ending in 7224 was charged $4.00 at CHICK-FIL-A." + trailer,
                [charge(400, "CHICK-FIL-A")]),
        fixture("no registered sign at all",
                "Fidelity Credit Card: Your card ending in 7224 was charged $4.00 at CHICK-FIL-A." + trailer,
                [charge(400, "CHICK-FIL-A")]),

        // Shortcuts variable interpolation can leave ragged whitespace.
        fixture("ragged whitespace",
                "  Fidelity\u{00AE}  Credit Card:  Your card ending in 7224 was charged $12.00 at  SPACED OUT MERCHANT ." + trailer + " ",
                [charge(1200, "SPACED OUT MERCHANT")]),

        // Two messages concatenated with no separator — observed in the user's own paste.
        fixture("two alerts concatenated",
                realAlert("36.00", "Georgia Tech Parking S") + realAlert("73.00", "CENTRAL ROCK MID (ATL)"),
                [charge(3600, "Georgia Tech Parking S"),
                 charge(7300, "CENTRAL ROCK MID (ATL)")]),

        // An unseen verb must be modelled, not coerced into a charge. Only charges are in
        // scope, but silently treating a new verb as one would corrupt the ledger.
        fixture("unseen verb",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was declined $12.00 at AMAZON.COM*MK1A2B3C4." + trailer,
                [charge(1200, "AMAZON.COM*MK1A2B3C4", verb: "declined")]),

        // Amount shapes.
        fixture("whole-dollar amount, no cents",
                realAlert("36", "SOME MERCHANT"),
                [charge(3600, "SOME MERCHANT")]),
        fixture("small amount",
                realAlert("0.99", "SOME MERCHANT"),
                [charge(99, "SOME MERCHANT")]),
    ]

    /// Cases from an adversarial pass, each one confirmed against this implementation.
    ///
    /// Every entry here produced a wrong value, a phantom row, a dropped charge, or a crash
    /// before the guards in `FidelityAlertParser` existed. The stated expectation is the
    /// *correct* behaviour, not merely the current one, so these fail loudly if a guard is
    /// removed. Ranked roughly by how bad the failure was.
    static let adversarial: [AlertFixture] = [

        // --- A silent 100x overstatement ---------------------------------------------
        // Any hop that swaps '.' and ',' (locale-aware relay, some transcoders) turned a
        // $2.50 charge into $250.00, because the converter stripped commas unconditionally.
        // Now rejected outright: "1,204" is genuinely ambiguous between the US thousands
        // reading and the European decimal one, so guessing is not available.
        fixture("comma decimal separator", realAlert("2,50", "BREEZE*00HS5MV"), []),
        fixture("misplaced comma grouping", realAlert("1204,99", "SOME MERCHANT"), []),
        fixture("short comma group", realAlert("1,20", "SOME MERCHANT"), []),
        fixture("four-digit comma group", realAlert("1,2345.00", "SOME MERCHANT"), []),

        // --- An uncatchable crash ----------------------------------------------------
        // `whole * 100` overflowed Int64 and the Swift runtime TRAPPED — the process died
        // rather than returning an error. A bounded whole part makes the arithmetic
        // provably safe; these now reject.
        fixture("amount above the sanity ceiling",
                realAlert("92,233,720,368,547,758.07", "SOME MERCHANT"), []),
        fixture("amount that would overflow Int64",
                realAlert("92,233,720,368,547,759.99", "SOME MERCHANT"), []),

        // --- A dropped charge --------------------------------------------------------
        // Total loss, with nothing in the output to notice. Each needs one character of
        // tolerance or normalisation.
        fixture("space after the dollar sign",
                realAlert(" 2.50", "BREEZE*00HS5MV"), [charge(250, "BREEZE*00HS5MV")]),
        fixture("zero-width space inside the amount",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2\u{200B}.50 at BREEZE*00HS5MV." + trailer,
                [charge(250, "BREEZE*00HS5MV")]),
        // Newlines are flattened to spaces so the alert survives at all — without that, `.`
        // cannot cross the newline and every terminator becomes unreachable, losing the
        // charge entirely. The cost is visible here: a newline that was inserted *inside* a
        // descriptor cannot be distinguished from a space that was always there, so the
        // merchant comes back as "BREEZE *00HS5MV". Losing the exact descriptor beats losing
        // the transaction, and the raw text is kept in the journal either way.
        fixture("newline inside the descriptor",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE\n*00HS5MV." + trailer,
                [charge(250, "BREEZE *00HS5MV")]),
        fixture("newline where the sentence period should be",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV\n" + trailer,
                [charge(250, "BREEZE*00HS5MV")]),
        // UTF-8 bytes of U+00AE decoded as Latin-1 — the classic mojibake of a re-encoding
        // relay. This breaks the ONLY match anchor, so every charge is lost, not one field.
        fixture("registered mark mojibake",
                "Fidelity\u{00C2}\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV." + trailer,
                [charge(250, "BREEZE*00HS5MV")]),

        // --- A wrong merchant, right money -------------------------------------------
        // The pattern's trailer alternative only recognises exact wording, so anything that
        // slips past it lets the lazy capture absorb the boilerplate into the descriptor.
        fixture("HTML-escaped ampersand in the trailer",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV. Msg&amp;Data rates may apply. Reply STOP to cancel.",
                [charge(250, "BREEZE*00HS5MV")]),
        fixture("trailer truncated mid-word",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $22.10 at WHOLE FOODS MKT #1234. Msg&Dat",
                [charge(2210, "WHOLE FOODS MKT #1234")]),
        fixture("trailing URL after the descriptor",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV. Fidelity.com/alerts",
                [charge(250, "BREEZE*00HS5MV")]),
        fixture("trailing call-back lure",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2,499.00 at WALMART. If this was not you, call 1-800-555-0142 immediately." + trailer,
                [charge(249900, "WALMART")]),
        fixture("unicode ellipsis truncation",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV\u{2026}",
                [charge(250, "BREEZE*00HS5MV")]),
        fixture("quoted-reply marker",
                "> Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at\n> BREEZE*00HS5MV." + trailer,
                [charge(250, "BREEZE*00HS5MV")]),

        // --- A phantom transaction ---------------------------------------------------
        // An empty descriptor defeated the old "merchant must be non-empty" guard, because
        // ". Msg&Data rates may apply" IS non-empty. The guard now rejects a descriptor
        // that starts with sentence punctuation.
        fixture("empty descriptor becomes the boilerplate",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at ." + trailer,
                []),

        // --- A card identity that can never match ------------------------------------
        // ICU's `\d` matches any Unicode decimal digit, so the card number was captured in
        // Arabic-Indic digits and could never equal the real card.
        fixture("arabic-indic digits in the card number",
                "Fidelity\u{00AE} Credit Card: Your card ending in \u{0667}\u{0662}\u{0662}\u{0664} was charged $2.50 at BREEZE*00HS5MV." + trailer,
                []),

        // --- Known and accepted ------------------------------------------------------
        // An unterminated alert cannot reach a terminator, and its capture is length-capped
        // so it cannot swallow the next alert. The unterminated one is LOST and the
        // well-formed one survives. Lossy, but strictly better than losing both.
        fixture("unterminated alert before a good one",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $22.10 at WHOLE FOODS MKT"
                    + realAlert("36.00", "Georgia Tech Parking S"),
                [charge(3600, "Georgia Tech Parking S")]),
        fixture("newline-separated, first unterminated",
                "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $36.00 at Georgia Tech Parking S.\n"
                    + realAlert("73.00", "CENTRAL ROCK MID (ATL)"),
                [charge(7300, "CENTRAL ROCK MID (ATL)")]),
    ]

    /// Must NOT produce an alert. A false positive here creates a phantom transaction.
    static let negativeCases: [AlertFixture] = [
        fixture("empty", "", []),
        fixture("whitespace only", "   \n  ", []),
        fixture("unrelated message", "Your Uber code is 1234", []),
        fixture("OTP", "Your verification code is 90210", []),
        fixture("Fidelity but not a card alert", "Fidelity Investments: your statement is ready", []),
        fixture("card phrase but no charge", "Your card ending in 7224 was used for a test.", []),
    ]
}
