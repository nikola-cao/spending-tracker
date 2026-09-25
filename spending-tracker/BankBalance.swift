//
//  BankBalance.swift
//  spending-tracker
//
//  The one number in this app that nothing else can work out.
//

import Foundation

/// How much the user says is in their bank account.
///
/// The only hand-maintained value here, and deliberately **not** in SwiftData. Everything in
/// the ledger is derived: a row can be thrown away and rebuilt from the raw journal, and
/// `resetStoreIfSchemaChanged` does exactly that by deleting the store outright whenever the
/// schema changes. A number the user typed is derivable from nothing, so storing it there
/// would mean it survived right up until the next schema bump and then vanished with no way
/// back. `UserDefaults` is not derived from the journal either, but it is not deleted by it.
///
/// Minor units, like every other amount here — an `Int` cannot drift by a cent the way a
/// stored `Double` can — and it goes through the same `Money` conversion a charge does.
enum BankBalance {

    /// Namespaced rather than a bare `"balance"`, which the next feature to want a balance
    /// would quietly collide with.
    nonisolated static let defaultsKey = "bankBalanceMinor"

    /// What the sheet accepts: a charge's amount, plus a leading minus.
    ///
    /// Longer than `Money.minorUnits(from:)` by exactly one rule, and that rule is the reason
    /// this exists rather than the caller reaching for the parser. An account can be overdrawn,
    /// so a balance of `-40.00` is a real thing to record, and refusing it would be a trap
    /// rather than a safeguard. A card *charge* can never be negative, so `Money` stays strict
    /// for the parsers and the minus is handled only here.
    nonisolated static func minorUnits(from text: String) -> Int? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // A leading `$` is a natural thing to paste — the decimal pad cannot type one, but a
        // paste can — and a minus may sit before it.
        //
        // `$-40` is deliberately not accepted. Nothing produces it, and a parser that takes
        // every shape someone might imagine grows rules nobody can predict; this one is
        // `[-][$]digits`, which is short enough to hold in your head.
        var isNegative = false
        if value.hasPrefix("-") {
            isNegative = true
            value.removeFirst()
        }
        if value.hasPrefix("$") { value.removeFirst() }

        // A bare "-", or "-" over something the parser rejects, is not a balance.
        guard let magnitude = Money.minorUnits(from: value) else { return nil }
        return isNegative ? -magnitude : magnitude
    }
}
