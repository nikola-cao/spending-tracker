//
//  BankBalance.swift
//  spending-tracker
//
//  The one number in this app that nothing else can work out.
//

import Foundation

/// How much the user says is in their bank account.
///
/// The balance itself is **not stored here any more, and not in SwiftData either** — it is
/// derived by folding the journal, so a rebuild restores it like everything else. See
/// `LedgerStore.bankBalance(from:)`. What is left in this type is the one-time handover from
/// the `UserDefaults` value an earlier version kept, which the journal could not restore.
///
/// Minor units, like every other amount here — an `Int` cannot drift by a cent the way a
/// stored `Double` can. Parsing is `Money.signedMinorUnits(from:)`, because a deposit may be
/// negative and an account can be overdrawn.
enum BankBalance {

    /// Namespaced rather than a bare `"balance"`, which the next feature to want a balance
    /// would quietly collide with.
    nonisolated static let legacyDefaultsKey = "bankBalanceMinor"

    /// A balance set before it was journalled, if one is still sitting in `UserDefaults`.
    ///
    /// Read, then adopted into the journal on the next drain and cleared. Deliberately two
    /// calls rather than a read-and-clear: clearing before the write would lose the value if
    /// the write failed, which is the opposite of the point.
    nonisolated static var legacyStoredValue: Int? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: legacyDefaultsKey) != nil else { return nil }
        return defaults.integer(forKey: legacyDefaultsKey)
    }

    nonisolated static func clearLegacyStoredValue() {
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }
}
