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
        // enter + result
        #expect(after.count == before + 2)

        let new = Array(after.suffix(2))
        #expect(new.first?.phase == "enter")
        #expect(new.last?.phase == "result")
        #expect(new.first?.runID == new.last?.runID)      // the pair is linked
        #expect(new.last?.rawText == realBody)
        #expect(new.last?.containsRegisteredTrademark == true)
        #expect(new.last?.hasFidelityPrefix == true)
        #expect(new.last?.mentionsFidelity == true)
        #expect(new.last?.charCount == realBody.count)
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
        // One "enter" record carrying the rejection note — no "result", and no zero row.
        #expect(after.count == before + 1)
        #expect(after.last?.phase == "enter")
        #expect(after.last?.note == "rejected: empty input")
    }
}
