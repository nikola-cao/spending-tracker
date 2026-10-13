//
//  LaunchLog.swift
//  spending-tracker
//
//  When this app's process last ran — the one question no other screen can answer.
//

import Foundation

/// A short ring of recent app launches, oldest first.
///
/// **Why this exists.** `LogTransactionIntent` writes the journal line as its first statement,
/// and `allowedExecutionTargets = [.main]` means the only way it can run is for iOS to launch
/// this app's own process. So when an alert goes missing, the first question is not *"what did
/// the app do with it"* but **"did the app run at all"** — and until now nothing on the device
/// could answer that. **Last captured** cannot: a day with no charges is a perfectly ordinary
/// day, and a stale value looks the same either way.
///
/// A launch is stamped from `App.init`, which runs for a background launch servicing the intent
/// exactly as it does for a launch by hand. So a window in which an alert arrived and no launch
/// was recorded is positive evidence that the intent never got the chance to run — the failure
/// mode the README warns about, and the one the app had no way to show.
///
/// **In `UserDefaults`, deliberately, and this is the exception to "everything the app knows
/// lives in the journal".** The journal is the record of what *arrived*: the money, the evidence,
/// the thing a rebuild restores. This is a record of the app's own process, which is not ledger
/// state — nothing is derived from it, no figure depends on it, and losing it costs nothing but
/// the answer to a diagnostic question. A line in the journal on every foreground would put the
/// app's own noise into the one file that has to stay readable as a record of what the sources
/// sent. (Contrast `BankBalance`'s legacy value, which *was* ledger state and had to move into
/// the journal precisely because a rebuild could not otherwise restore it.)
nonisolated enum LaunchLog {

    /// Namespaced rather than a bare `"launches"`, which the next feature to want a launch
    /// record would quietly collide with. Exposed for the same reason
    /// `BankBalance.legacyDefaultsKey` is: it is process-wide state with no injection point, so
    /// the test that exercises it has to save and restore the value it finds.
    nonisolated static let defaultsKey = "recentAppLaunches"

    /// How many launches are remembered. Enough to show a pattern across a few days of ordinary
    /// use — *"the app only ever runs when I open it"* is the pattern worth seeing — without
    /// turning the Diagnostics screen into a log viewer.
    static let capacity = 8

    /// Stamps a launch and returns the whole log, newest first.
    ///
    /// Called from `App.init`, so a background launch stamps it too. Ordered by insertion rather
    /// than sorted: two launches inside one second are indistinguishable by timestamp, which is
    /// the same reason the journal trusts file position over `receivedAt`.
    @discardableResult
    static func record(now: Date = Date()) -> [Date] {
        var launches = recent
        launches.append(now)
        if launches.count > capacity {
            launches.removeFirst(launches.count - capacity)
        }
        UserDefaults.standard.set(launches, forKey: defaultsKey)
        return launches.reversed()
    }

    /// Every launch still remembered, oldest first. Empty on a fresh install, and empty after a
    /// reinstall, which is itself worth knowing — see the note in `DiagnosticsView`.
    static var recent: [Date] {
        (UserDefaults.standard.array(forKey: defaultsKey) as? [Date]) ?? []
    }

    /// Newest first, which is the order a person reads.
    static var recentNewestFirst: [Date] { recent.reversed() }

    /// The launch before the current one — the gap that matters when something is missing.
    ///
    /// Nil when this is the only launch on record, which is the state a fresh install is in and
    /// is not a gap at all: there is no earlier moment that could have caught anything.
    static var previous: Date? {
        let launches = recent
        return launches.count >= 2 ? launches[launches.count - 2] : nil
    }
}
