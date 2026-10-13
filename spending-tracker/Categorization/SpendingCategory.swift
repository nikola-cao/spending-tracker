//
//  SpendingCategory.swift
//  spending-tracker
//
//  The vocabulary a category is stored and shown in.
//

import Foundation

/// The set of categories, as **tokens** rather than as a Swift enum.
///
/// A journal line outlives the code that wrote it. An `enum` with five cases would make a line
/// naming a sixth category unreadable — and unreadable is not a harmless outcome here: the
/// parser that rejects it is the same parser the retention purge consults, so the line would be
/// dropped after a week and a decision the user made would simply cease to exist. Storing a
/// token and validating only its *shape* means the set can grow, or be renamed in the UI,
/// without invalidating a single line already on disk.
///
/// The cost is that nothing stops a line naming a category this build has never heard of, so
/// `displayName` has to have an answer for one. It shows the token itself, which is honest: the
/// row says what the journal actually holds rather than pretending the value is missing.
///
/// `nonisolated` because this target defaults every unannotated type to `@MainActor`, and the
/// classification pass and the parser both need to reach it off the main actor.
nonisolated enum SpendingCategory {

    /// The five, in the order the picker and the filter offer them.
    ///
    /// Ordered by how often they are reached for rather than alphabetically, because it is a
    /// picker a person taps and `dining` is the one that gets chosen most.
    static let all = ["dining", "grocery", "retail", "transportation", "miscellaneous"]

    /// What a person reads on the chip. Separate from the token so the wording can change —
    /// `retail` to `Shopping` — without touching a line that was written months ago.
    private static let names = [
        "dining": "Dining",
        "grocery": "Grocery",
        "retail": "Retail",
        "transportation": "Transportation",
        "miscellaneous": "Misc",
    ]

    static func isKnown(_ token: String) -> Bool { names[token] != nil }

    /// The label for a token, including one this build does not know.
    ///
    /// Empty in, empty out: the caller uses `""` to mean "no category", and that has to stay
    /// distinguishable from a category whose name happens to be blank.
    static func displayName(for token: String) -> String {
        guard !token.isEmpty else { return "" }
        if let known = names[token] { return known }
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// Whether a token is shaped like a category, for the parser.
    ///
    /// **A shape test, never a membership test.** Membership would be the tighter check and the
    /// wrong one: it would make every line naming a category added later a *rejected* line, and
    /// a rejected instruction line is one the retention purge is allowed to discard.
    ///
    /// Lowercase, no spaces — the token goes into a `|`-delimited line where the merchant is the
    /// only field allowed to be free text, so a token that could contain a delimiter or a space
    /// has to be refused at the door rather than escaped.
    static func isWellFormed(_ token: String) -> Bool {
        guard (1...32).contains(token.count) else { return false }
        guard let first = token.first, first.isLowercase || first.isNumber else { return false }
        return token.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }
}
