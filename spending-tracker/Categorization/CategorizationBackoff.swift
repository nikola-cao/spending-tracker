//
//  CategorizationBackoff.swift
//  spending-tracker
//
//  How long before a merchant may be asked about again.
//

import Foundation

/// When each merchant may be asked about again.
///
/// **A throttle, not a queue** — and that distinction is the whole reason this is allowed to live
/// in `UserDefaults` while nothing else about a category may. The backlog is a *question* asked
/// of the store ("which merchants have no answer?"), recomputed from the journal every time; this
/// only spaces the asking out. Losing it costs a few wasted requests and never a category, which
/// is exactly the standing `LaunchLog` has: process state that nothing is derived from.
///
/// Keyed **per merchant** rather than by one counter, for two reasons that both showed up in the
/// design. A merchant the service keeps refusing must not stall every other merchant behind it;
/// and one success must not clear the gate for a batch that failed beside it, which is what a
/// single shared counter does — one good answer resets the interval and the whole failing batch
/// is retried on the very next foreground, forever.
nonisolated enum CategorizationBackoff {

    /// The first retry, doubling from there.
    ///
    /// Half a minute is deliberately impatient: it means a merchant captured in a tunnel is
    /// usually answered by the time the user has looked at the app twice. It doubles away from
    /// there, so a merchant that keeps failing costs a vanishing amount of attention.
    static let baseInterval: TimeInterval = 30

    /// The ceiling.
    ///
    /// A day, because a finer schedule would buy nothing: the pass only runs while the app is
    /// open, so an hour-long wait is almost always spent with the app closed and the attempt is
    /// made at the next foreground anyway. What the cap really does is bound the cost of a
    /// merchant this service will never be able to read — one request a day, forever, which is
    /// cheap enough that nothing has to be given up on.
    static let maximumInterval: TimeInterval = 24 * 60 * 60

    /// Namespaced like `LaunchLog.defaultsKey`, so a later feature wanting its own attempt record
    /// does not quietly collide with this one.
    static let defaultsKey = "categorization.attempts"

    struct Record: Codable, Sendable, Equatable {
        var attempts: Int
        var lastAttemptAt: Date
    }

    static var all: [String: Record] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return [:] }
        return records
    }

    /// Whether this merchant may be asked about now.
    ///
    /// A merchant with no record at all is always due — the first attempt is never delayed.
    static func isDue(_ key: String, now: Date) -> Bool {
        guard let record = all[key] else { return true }
        return now.timeIntervalSince(record.lastAttemptAt) >= interval(after: record.attempts)
    }

    /// When this merchant becomes due again, or nil when it is due now. For the Diagnostics
    /// screen, which is the only place the wait is visible at all.
    static func nextAttempt(for key: String, now: Date) -> Date? {
        guard let record = all[key] else { return nil }
        let due = record.lastAttemptAt.addingTimeInterval(interval(after: record.attempts))
        return due > now ? due : nil
    }

    /// Counts one failed attempt against each of these merchants.
    ///
    /// Called for a failed *call* and for each merchant a reply declined. Never called for a
    /// blocked run — a refused key is not evidence about any merchant, and counting it would
    /// march every merchant in the ledger toward the daily ceiling over a typo.
    static func record(_ keys: [String], at now: Date) {
        guard !keys.isEmpty else { return }

        var records = all
        for key in keys {
            let previous = records[key]?.attempts ?? 0
            records[key] = Record(attempts: previous + 1, lastAttemptAt: now)
        }
        write(records)
    }

    /// Forgets a merchant's history, which is what an answer does.
    ///
    /// A merchant that has been answered is not throttled at all, so a later correction by hand —
    /// deleting the rule in the Raw journal — puts it straight back in the queue with no wait.
    static func clear(_ keys: [String]) {
        guard !keys.isEmpty else { return }
        var records = all
        for key in keys { records.removeValue(forKey: key) }
        write(records)
    }

    /// Forgets every merchant's history. The escape hatch behind "Try again now".
    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// `30s · 2^(n-1)`, capped.
    ///
    /// The exponent is clamped rather than the product being clamped alone: doubling a
    /// `TimeInterval` past 2^20 seconds is already far beyond the cap, and leaving the shift
    /// unbounded would mean an attempt count large enough to make the arithmetic meaningless
    /// before it is capped.
    static func interval(after attempts: Int) -> TimeInterval {
        guard attempts > 0 else { return 0 }
        let exponent = min(attempts - 1, 20)
        return min(baseInterval * pow(2, Double(exponent)), maximumInterval)
    }

    private static func write(_ records: [String: Record]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
