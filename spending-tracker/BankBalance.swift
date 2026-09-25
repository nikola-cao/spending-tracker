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
/// stored `Double` can. Parsing is `Money.signedMinorUnits(from:)`, because a deposit may be
/// negative and an account can be overdrawn.
enum BankBalance {

    /// Namespaced rather than a bare `"balance"`, which the next feature to want a balance
    /// would quietly collide with.
    nonisolated static let defaultsKey = "bankBalanceMinor"
}
