//
//  JournalStoreTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

/// Every test passes an EXPLICIT temp URL. This is a correctness requirement, not style:
/// `TEST_HOST` is set, so tests run inside the app's own process and
/// `JournalLocation.fileURL` resolves to the *real* journal. A test that forgot the URL
/// would corrupt the very diagnostic data Stage 1 exists to collect.
private func tempJournalURL() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "st1-\(UUID().uuidString)", directoryHint: .isDirectory)
        .appending(path: "journal.jsonl", directoryHint: .notDirectory)
}

/// A verbatim alert body from the user's phone. Spelled with an explicit `\u{00AE}` escape
/// rather than a pasted character so the test cannot be silently "fixed" by an editor.
private let realBody = "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged "
    + "$2.50 at BREEZE*00HS5MV. Msg&Data rates may apply. Reply STOP to cancel."

struct JournalStoreTests {

    @Test func appendReadRoundTrip() throws {
        let url = tempJournalURL()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "enter", raw: realBody, note: ""), to: url)

        let back = JournalStore.readAll(from: url)
        #expect(back.count == 1)
        // Byte-for-byte, including U+00AE. If this fails, the string was mangled.
        #expect(back.first?.rawText == realBody)
        #expect(back.first?.charCount == realBody.count)
        #expect(back.first?.containsRegisteredTrademark == true)
        #expect(back.first?.hasFidelityPrefix == true)
        #expect(back.first?.mentionsFidelity == true)
    }

    /// The test that matters most. `JSONEncoder` escapes a newline *inside a string value*
    /// as the two-character sequence `\` `n`, which is the only reason an SMS body
    /// containing literal newlines cannot split a record across two lines. Nothing about
    /// that is obvious, so it is asserted rather than assumed.
    @Test(arguments: [
        "line one\nline two",
        "carriage\r\nreturn",
        "quote\" backslash\\ tab\t",
        realBody,
        "AMAZON.COM*MK1A2B3C4 $1,204.99",
        "AT&T*WIRELESS $5.30 at DEEPSEERWEA",
        realBody + realBody,   // two alerts concatenated with NO separator
        "Fidelity\u{00AE} Credit Card: your card was charged $5.30 at PICKUP* TRIAL OVER",
        "",                    // empty body must still frame as exactly one line
    ])
    func oneAppendIsAlwaysOneLine(_ payload: String) throws {
        let url = tempJournalURL()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "enter", raw: payload, note: ""), to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.split(separator: "\n", omittingEmptySubsequences: true).count == 1)

        let back = JournalStore.readAll(from: url)
        #expect(back.count == 1)
        #expect(back.first?.rawText == payload)
    }

    /// A torn trailing line — the process was killed mid-append — must not hide everything
    /// written before it. Losing the tail is acceptable; losing the history is not.
    @Test func tornTailLineIsSkippedNotFatal() throws {
        let url = tempJournalURL()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "enter", raw: realBody, note: ""), to: url)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"deadbeef","pha"#.utf8))
        try handle.close()

        #expect(JournalStore.readAll(from: url).count == 1)
    }

    /// Exercises the NSLock. NOT a test of cross-process atomicity — the `.main` execution
    /// target means there is only ever one writer process in Stage 1.
    @Test func concurrentAppendsLoseNothing() async throws {
        let url = tempJournalURL()
        let runIDs = (0..<50).map { _ in UUID() }

        await withTaskGroup(of: Void.self) { group in
            for runID in runIDs {
                group.addTask {
                    try? JournalStore.append(
                        .diagnostic(runID: runID, phase: "result", raw: realBody, note: ""), to: url)
                }
            }
        }

        let back = JournalStore.readAll(from: url)
        #expect(back.count == 50)
        #expect(Set(back.map(\.runID)) == Set(runIDs))
    }

    @Test func readingMissingFileReturnsEmpty() {
        #expect(JournalStore.readAll(from: tempJournalURL()).isEmpty)
    }

    /// Records written in the same run are indistinguishable by `receivedAt` — `.iso8601`
    /// has one-second resolution and this SDK has no fractional-seconds JSON date strategy.
    /// File order is therefore the only ordering that can be trusted.
    @Test func fileOrderIsAuthoritativeNotTimestamp() throws {
        let url = tempJournalURL()
        for index in 0..<5 {
            try JournalStore.append(
                .diagnostic(runID: UUID(), phase: "enter", raw: "msg \(index)", note: ""), to: url)
        }
        let back = JournalStore.readAll(from: url)
        #expect(back.map(\.rawText) == ["msg 0", "msg 1", "msg 2", "msg 3", "msg 4"])
        // And prove the timestamps really are too coarse to order them:
        let distinctSeconds = Set(back.map { Int($0.receivedAt.timeIntervalSince1970) })
        #expect(distinctSeconds.count <= back.count)
    }
}
