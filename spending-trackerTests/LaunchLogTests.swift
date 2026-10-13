//
//  LaunchLogTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

/// The ring of app launches the Diagnostics screen reads.
///
/// `UserDefaults` is process-wide and the app's own launch has already stamped this key by the
/// time these run — `TEST_HOST` means the suite runs inside the app's process — so every test
/// saves and restores whatever it finds, and the suite is serialized for the same reason
/// `LedgerStoreTests` is.
@Suite(.serialized)
struct LaunchLogTests {

    /// Runs `body` against a log this test owns, putting back what was there afterwards.
    private func withLogOfItsOwn(_ body: () throws -> Void) rethrows {
        let saved = UserDefaults.standard.array(forKey: LaunchLog.defaultsKey)
        UserDefaults.standard.removeObject(forKey: LaunchLog.defaultsKey)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: LaunchLog.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: LaunchLog.defaultsKey)
            }
        }
        try body()
    }

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func launchesAreRememberedNewestFirst() throws {
        try withLogOfItsOwn {
            for index in 0..<3 {
                LaunchLog.record(now: base.addingTimeInterval(Double(index)))
            }

            #expect(LaunchLog.recent.count == 3)
            #expect(LaunchLog.recentNewestFirst.first == base.addingTimeInterval(2))
            #expect(LaunchLog.recentNewestFirst.last == base)
        }
    }

    /// The launch before this one is the gap that matters when an alert went missing, and it is
    /// nil on a fresh install — which is not a gap: there is no earlier moment that could have
    /// caught anything.
    @Test func previousIsNilUntilThereAreTwoLaunches() throws {
        try withLogOfItsOwn {
            #expect(LaunchLog.previous == nil, "nothing recorded at all")

            LaunchLog.record(now: base)
            #expect(LaunchLog.previous == nil, "one launch is not a gap")

            LaunchLog.record(now: base.addingTimeInterval(3600))
            #expect(LaunchLog.previous == base)
        }
    }

    /// The ring is bounded, and it drops the OLDEST — the question is always about recent
    /// launches, so the far end is the end worth losing.
    @Test func theLogKeepsOnlyTheMostRecentLaunches() throws {
        try withLogOfItsOwn {
            let count = LaunchLog.capacity + 5
            for index in 0..<count {
                LaunchLog.record(now: base.addingTimeInterval(Double(index)))
            }

            #expect(LaunchLog.recent.count == LaunchLog.capacity)
            #expect(LaunchLog.recent.first == base.addingTimeInterval(Double(count - LaunchLog.capacity)))
            #expect(LaunchLog.recent.last == base.addingTimeInterval(Double(count - 1)))
        }
    }

    /// Order is insertion, not timestamp. Two launches inside one second are indistinguishable
    /// by `Date`, which is the same reason the journal trusts file position over `receivedAt`.
    @Test func launchesWithinTheSameSecondKeepTheirOrder() throws {
        try withLogOfItsOwn {
            LaunchLog.record(now: base)
            LaunchLog.record(now: base)

            #expect(LaunchLog.recent.count == 2)
            #expect(LaunchLog.previous == base)
        }
    }
}
