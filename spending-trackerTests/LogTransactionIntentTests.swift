//
//  LogTransactionIntentTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

/// Drives the REAL intent through the REAL `@Parameter` machinery.
///
/// Caveat worth stating: the intent resolves its own journal URL, so these tests append to
/// the *real* journal when run on a device (`TEST_HOST` makes that the app's container).
/// Every assertion is therefore a before/after delta rather than an absolute count, so it
/// stays correct regardless. The extra rows are recognisable by their body text.
@MainActor
struct LogTransactionIntentTests {

    private let realBody = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
        + "$2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel."

    @Test func realBodyIsAcceptedAndRecorded() async throws {
        let before = JournalStore.readAll(from: JournalLocation.fileURL).count

        // `let`, not `var`: it compiles, which proves @Parameter's setter is nonmutating.
        let intent = LogTransactionIntent()
        intent.message = realBody
        _ = try await intent.perform()

        let after = JournalStore.readAll(from: JournalLocation.fileURL)
        // ONE line per alert. This was an enter/result pair until the pair's diagnostic job
        // was done and the second copy stopped being worth its size.
        #expect(after.count == before + 1)

        let new = try #require(after.last)
        #expect(new.phase == JournalRecord.capturePhase)
        #expect(new.rawText == realBody)
        #expect(new.containsRegisteredTrademark == true)
        #expect(new.hasFidelityPrefix == true)
        #expect(new.mentionsFidelity == true)
        #expect(new.charCount == realBody.count)
    }

    /// An empty invocation is a Shortcuts plumbing bug, and is exactly the evidence worth
    /// having. It is journalled with a note rather than dropped, so that "ran with empty
    /// input" stays distinguishable from "never ran" — the single most important
    /// distinction this intent exists to make.
    @Test(arguments: ["", " ", "\n", "   \t \n  "])
    func emptyOrWhitespaceInputIsJournalledWithANote(_ payload: String) async throws {
        let before = JournalStore.readAll(from: JournalLocation.fileURL).count

        // `let`, not `var`: it compiles, which proves @Parameter's setter is nonmutating.
        let intent = LogTransactionIntent()
        intent.message = payload
        _ = try await intent.perform()

        let after = JournalStore.readAll(from: JournalLocation.fileURL)
        // One record carrying the rejection note — and no zero row.
        #expect(after.count == before + 1)
        #expect(after.last?.phase == JournalRecord.capturePhase)
        #expect(after.last?.note == "rejected: empty input")
    }
}
