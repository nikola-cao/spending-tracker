//
//  CategorizationBackoffTests.swift
//  spending-trackerTests
//
//  The retry schedule. It lives in `UserDefaults`, so every test here owns the whole key —
//  serialized, and cleaned up after itself.
//

import Foundation
import Testing
@testable import spending_tracker

@Suite(.serialized)
struct CategorizationBackoffTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func theScheduleDoublesAndThenStops() {
        // Never delayed before it has been tried.
        #expect(CategorizationBackoff.interval(after: 0) == 0)
        #expect(CategorizationBackoff.interval(after: 1) == 30)
        #expect(CategorizationBackoff.interval(after: 2) == 60)
        #expect(CategorizationBackoff.interval(after: 3) == 120)

        // A day is the ceiling, and it holds however long the failures go on. This is what makes
        // "never gives up" affordable: the worst case is one request a day, forever.
        #expect(CategorizationBackoff.interval(after: 20) == CategorizationBackoff.maximumInterval)
        #expect(CategorizationBackoff.interval(after: 10_000) == CategorizationBackoff.maximumInterval)
    }

    @Test func anUntriedMerchantIsDueImmediately() {
        CategorizationBackoff.clearAll()
        #expect(CategorizationBackoff.isDue("WHOLE FOODS MKT", now: now))
        #expect(CategorizationBackoff.nextAttempt(for: "WHOLE FOODS MKT", now: now) == nil)
    }

    @Test func aFailedMerchantWaitsAndThenComesBack() {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record(["BREEZE"], at: now)

        #expect(!CategorizationBackoff.isDue("BREEZE", now: now))
        #expect(!CategorizationBackoff.isDue("BREEZE", now: now.addingTimeInterval(29)))
        #expect(CategorizationBackoff.isDue("BREEZE", now: now.addingTimeInterval(30)))

        // And the wait grows with each failure.
        CategorizationBackoff.record(["BREEZE"], at: now.addingTimeInterval(30))
        #expect(!CategorizationBackoff.isDue("BREEZE", now: now.addingTimeInterval(89)))
        #expect(CategorizationBackoff.isDue("BREEZE", now: now.addingTimeInterval(90)))
    }

    /// Per merchant, so one shop this service cannot read cannot hold up every other one behind
    /// it — which is what a single shared counter does.
    @Test func oneMerchantsFailuresDoNotHoldUpAnother() {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record(["BREEZE"], at: now)

        #expect(!CategorizationBackoff.isDue("BREEZE", now: now))
        #expect(CategorizationBackoff.isDue("WHOLE FOODS MKT", now: now))
    }

    /// And a success clears that merchant entirely, so nothing accumulates against a shop that is
    /// working.
    @Test func anAnswerForgetsTheHistory() {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record(["BREEZE"], at: now)
        CategorizationBackoff.record(["BREEZE"], at: now)
        #expect(CategorizationBackoff.all["BREEZE"]?.attempts == 2)

        CategorizationBackoff.clear(["BREEZE"])

        #expect(CategorizationBackoff.all["BREEZE"] == nil)
        #expect(CategorizationBackoff.isDue("BREEZE", now: now))
    }

    @Test func nextAttemptReportsTheWaitThatIsLeft() throws {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record(["BREEZE"], at: now)

        let due = try #require(CategorizationBackoff.nextAttempt(for: "BREEZE", now: now))
        #expect(due == now.addingTimeInterval(30))
    }

    /// The escape hatch, which is the only way out of a long wait without waiting it out.
    @Test func clearingEverythingPutsEveryMerchantBackInTheQueue() {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record(["BREEZE", "WHOLE FOODS MKT"], at: now)
        #expect(CategorizationBackoff.all.count == 2)

        CategorizationBackoff.clearAll()

        #expect(CategorizationBackoff.all.isEmpty)
        #expect(CategorizationBackoff.isDue("BREEZE", now: now))
        #expect(CategorizationBackoff.isDue("WHOLE FOODS MKT", now: now))
    }

    @Test func recordingNothingChangesNothing() {
        CategorizationBackoff.clearAll()
        CategorizationBackoff.record([], at: now)
        #expect(CategorizationBackoff.all.isEmpty)
    }
}
