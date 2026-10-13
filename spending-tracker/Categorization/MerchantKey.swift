//
//  MerchantKey.swift
//  spending-tracker
//
//  The stable key a merchant's spelling is reduced to.
//

import Foundation

/// Reduces a captured descriptor to the key a category is remembered under.
///
/// **Why this has to exist.** A descriptor is not a merchant name. Fidelity prints the issuer's
/// pre-truncated string with a `*` store code on the end, Amex prints its own enriched name, and
/// the same shop therefore arrives as several different strings. The test corpus already holds
/// three spellings of one supermarket:
///
///     WHOLE FOODS MKT
///     WHOLE FOODS MKT #12
///     WHOLE FOODS MKT #1234
///
/// and two of one card-processed merchant that differ by a single space —
/// `BREEZE*00HS5MV` and `BREEZE *00HS5MV`. Keyed on the raw string, every one of those is a
/// different merchant: the cache would miss, the AI would be asked again about the same grocer
/// forever, and a rule the user set by hand would apply to exactly one of the spellings.
///
/// **Computed at read time, never stored.** A rule line carries the merchant *verbatim* and the
/// key is derived from it on every drain. That is what makes a category rebuildable: if this
/// function is ever changed, every stored rule re-derives under the new rules instead of being
/// orphaned by a stored key that no longer recomputes to itself.
///
/// **Deliberately conservative.** No edit distance and no fuzzy matching: a false merge gives
/// two unrelated merchants one category, which is invisible and wrong, while a miss costs one
/// extra API call and one more rule line. Every judgement here is pushed toward the miss.
///
/// `nonisolated` because this target defaults every unannotated type to `@MainActor`, and a
/// pure string function that can only run on the main actor would be uncallable from the
/// classification pass.
nonisolated enum MerchantKey {

    /// The shortest stem a `*` truncation is allowed to leave behind.
    ///
    /// The issuer's store code is separated by `*`, so cutting there is usually exactly right:
    /// `BREEZE*00HS5MV` is Breeze, and `AMAZON.COM*MK1A2B3C4` is Amazon. But a *short* stem is
    /// the signature of a card processor rather than a merchant — `SQ *COFFEE` is Square
    /// relaying a coffee shop, and cutting it to `SQ` would give every Square reader in the
    /// country one shared category. Below this length the whole string is used instead, which
    /// can only ever cost a call.
    static let minimumStemLength = 4

    /// The key for a merchant descriptor. Empty in, empty out.
    static func normalize(_ merchant: String) -> String {
        let raw = merchant.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !raw.isEmpty else { return "" }

        // 1. Cut the issuer's store code, unless the stem is too short to be the merchant.
        let head = raw
            .split(separator: "*", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        let source = head.count >= minimumStemLength ? head : raw

        // 2. Keep letters, digits and `&`; everything else becomes a separator. `isLetter`
        //    rather than an ASCII range on purpose — an accented letter is part of the name,
        //    and keeping it only ever splits two keys apart, which is the safe direction.
        let mapped = source.map { character -> Character in
            character.isLetter || character.isNumber || character == "&" ? character : " "
        }

        // 3. Drop the store number — `#1234`, `12`, `0012` — and the domain tail of a web
        //    merchant, so `NETFLIX.COM` and `AMAZON.COM` reduce rather than keeping a token
        //    that is never part of the name. A single digit survives, so `7 ELEVEN` stays whole.
        let tokens = String(mapped)
            .split(separator: " ")
            .map(String.init)
            .filter { !isStoreNumber($0) }
        let withoutDomain = dropDomainTail(tokens)

        // 4. Nothing left to key on — a descriptor that was *only* a store number. The whole
        //    string is a worse key than a reduced one but a far better one than an empty
        //    string, which would let one unreadable merchant collide with another.
        let key = withoutDomain.joined(separator: " ")
        return key.isEmpty ? raw : key
    }

    /// Whether a token is a store number rather than part of the name.
    ///
    /// Two or more digits, all digits. The threshold matters: `7 ELEVEN` and `76` are names,
    /// and dropping their number would leave `ELEVEN` — a key that matches nothing else and
    /// reads like a bug in the row it is shown on.
    private static func isStoreNumber(_ token: String) -> Bool {
        token.count >= 2 && token.allSatisfy(\.isNumber)
    }

    /// Drops a trailing `COM`/`NET`/`ORG`/`CO`/`US` token, which `.` and `,` turned into a
    /// separate word. Only the tail, and only when something is left: a merchant genuinely
    /// named `CO` keeps its name rather than reducing to nothing.
    private static func dropDomainTail(_ tokens: [String]) -> [String] {
        let domains: Set<String> = ["COM", "NET", "ORG", "CO", "US"]
        guard tokens.count > 1, let last = tokens.last, domains.contains(last) else { return tokens }
        return Array(tokens.dropLast())
    }
}
