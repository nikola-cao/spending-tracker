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

    // MARK: - Removing lines

    /// A line the current schema cannot decode is **evidence**, and every rewrite used to
    /// destroy it: the file was rebuilt by re-encoding only the records `readAll` had managed
    /// to decode. `JournalRecord`'s own note describes the day a new field made every older
    /// line undecodable — which is exactly when this would have bitten, silently.
    @Test func aRewriteKeepsLinesItCannotDecode() throws {
        let url = tempJournalURL()
        let doomed = UUID()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "capture", raw: realBody, note: ""), to: url)
        try JournalStore.append(
            .diagnostic(runID: doomed, phase: "capture", raw: "delete me", note: ""), to: url)

        // Valid JSON, a shape this build does not know how to read.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"id":"deadbeef","phase":"capture"}"#.utf8) + Data([0x0A]))
        try handle.close()

        let removed = try JournalStore.remove(from: url) { $0.runID == doomed }

        #expect(removed == 1)
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(raw.contains(#""id":"deadbeef""#), "an undecodable line is carried through, not dropped")
        #expect(raw.contains(realBody))
        #expect(!raw.contains("delete me"))
    }

    /// Removing nothing must not rewrite the file. This is what keeps a journal with nothing to
    /// purge from being rewritten on every foreground — and what makes `remove` safe to call on
    /// a file it has no business touching.
    @Test func removingNothingLeavesTheFileAlone() throws {
        let url = tempJournalURL()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "capture", raw: realBody, note: ""), to: url)
        let before = try Data(contentsOf: url)

        let removed = try JournalStore.remove(from: url) { _ in false }

        #expect(removed == 0)
        #expect(try Data(contentsOf: url) == before)
    }

    /// A missing journal is not a failure — a fresh install has nothing to remove.
    @Test func removingFromAMissingJournalIsHarmless() throws {
        #expect(try JournalStore.remove(from: tempJournalURL()) { _ in true } == 0)
    }

    /// One damaged byte must not take the whole file with it.
    ///
    /// Decoding the journal as a single UTF-8 string fails the entire read if any byte anywhere
    /// is invalid — and a torn write is a real thing here, because the journal is appended to by
    /// a process that can be killed mid-write. Whole-file decoding would stop every deletion,
    /// and through the purge it would quietly stop the retention window as well. Decoded per
    /// line, the damage stays on the line it is on, and that line goes back out as the bytes it
    /// came in as.
    @Test func aDamagedByteDoesNotMakeTheJournalUnreadable() throws {
        let url = tempJournalURL()
        let doomed = UUID()
        try JournalStore.append(
            .diagnostic(runID: UUID(), phase: "capture", raw: realBody, note: ""), to: url)
        try JournalStore.append(
            .diagnostic(runID: doomed, phase: "capture", raw: "delete me", note: ""), to: url)

        // A trailing line torn off inside a multi-byte character: `{"` then half of a euro sign.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x7B, 0x22, 0xE2, 0x82]))
        try handle.write(contentsOf: Data([0x0A]))
        try handle.close()

        let removed = try JournalStore.remove(from: url) { $0.runID == doomed }

        #expect(removed == 1, "a damaged line must not stop the removal")
        let raw = try Data(contentsOf: url)
        #expect(raw.range(of: Data(realBody.utf8)) != nil, "the good lines are untouched")
        #expect(raw.range(of: Data([0xE2, 0x82])) != nil,
                "the damaged bytes come back out exactly as they went in")
    }

    /// The reason `remove` is one primitive rather than `readAll` + filter + a write.
    ///
    /// The composed shape takes the lock three separate times, so an alert appended in the gap
    /// is read as absent and then written away. That alert can be a real charge, and because
    /// the ledger is derived from this file, losing it loses the charge everywhere. Under one
    /// lock hold the append can only land before the read — where the predicate does not match
    /// it — or after the write, where it survives.
    @Test func anAppendDuringARemovalIsNeverLost() async throws {
        let url = tempJournalURL()
        let doomed = UUID()
        for index in 0..<40 {
            try JournalStore.append(
                .diagnostic(runID: doomed, phase: "capture", raw: "junk \(index)", note: ""), to: url)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? JournalStore.remove(from: url) { $0.runID == doomed }
            }
            group.addTask {
                try? JournalStore.append(
                    .diagnostic(runID: UUID(), phase: "capture", raw: realBody, note: ""), to: url)
            }
        }

        let back = JournalStore.readAll(from: url)
        #expect(back.allSatisfy { $0.runID != doomed }, "the removal still has to happen")
        #expect(back.contains { $0.rawText == realBody },
                "an alert that arrived during a rewrite must survive it")
    }

    // MARK: - Lines that cannot be read back

    /// Bytes with no trailing newline, which is exactly what a kill in the middle of an append
    /// leaves: `append` frames the record with its newline LAST, so a partial write is always a
    /// line without one.
    private func leaveATornFragment(_ bytes: Data, at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            _ = FileManager.default.createFile(atPath: url.path(percentEncoded: false), contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    private func captured(_ body: String) -> JournalRecord {
        .diagnostic(runID: UUID(), phase: JournalRecord.capturePhase, raw: body, note: "")
    }

    /// A line that does not decode is **reported**, not dropped.
    ///
    /// This is the whole reason `read(from:)` is a shape of its own rather than `readAll`.
    /// Dropping the line made "a line arrived and cannot be read" indistinguishable from "no
    /// line ever arrived" — on the Raw journal screen, in `diagnostics()`, and in the drain,
    /// which all read through the same function. And the store is derived from this file, so
    /// that difference is a transaction that exists or one that does not.
    @Test func aTornTailIsReportedRatherThanDropped() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured(realBody), to: url)

        let fragment = Data(#"{"id":"deadbeef","pha"#.utf8)
        try leaveATornFragment(fragment, at: url)

        let read = JournalStore.read(from: url)
        #expect(read.records.count == 1, "the good line before it is still readable")
        #expect(read.damaged.count == 1)
        #expect(read.damaged.first == fragment, "it comes back as the bytes it actually is")
        #expect(read.damagedByteCount == fragment.count)
        #expect(read.isEmpty == false)
    }

    /// A file holding nothing but a damaged line is not an empty journal.
    ///
    /// The sharpest version of the same point: `readAll` sees no records, so every caller that
    /// asks only for records is looking at a journal that appears never to have been written to
    /// — while the file plain as day holds bytes.
    @Test func aFileOfNothingButADamagedLineIsNotEmpty() throws {
        let url = tempJournalURL()
        try leaveATornFragment(Data([0x7B, 0x22, 0xE2, 0x82]), at: url)

        #expect(JournalStore.readAll(from: url).isEmpty)
        #expect(JournalStore.read(from: url).isEmpty == false)
        #expect(JournalStore.read(from: url).damaged.count == 1)
    }

    /// A bad byte in the middle of the file must not blank the whole journal.
    ///
    /// The read used to decode the file as ONE UTF-8 string, so a single invalid byte anywhere
    /// returned nothing at all — every screen would show an empty journal while the feed still
    /// showed rows derived from it a moment earlier. Per line, the damage stays on its line.
    @Test func anInvalidByteInTheMiddleHidesNothing() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured("before"), to: url)
        // A terminated line torn off inside a multi-byte character: `{"` then half a euro sign.
        try leaveATornFragment(Data([0x7B, 0x22, 0xE2, 0x82, 0x0A]), at: url)
        try JournalStore.append(captured("after"), to: url)

        let read = JournalStore.read(from: url)
        #expect(read.records.map(\.rawText) == ["before", "after"])
        #expect(read.damaged.count == 1)
        #expect(JournalStore.readAll(from: url).map(\.rawText) == ["before", "after"])
    }

    /// An append after a torn tail frames the file first, so the next alert is not written onto
    /// the end of the fragment.
    ///
    /// Without that guard the two records become one undecodable line, which means a kill during
    /// one append takes the *following* alert with it — an alert that arrived intact, and that
    /// nothing anywhere would record as having arrived at all. One damaged line is a loss; two,
    /// the second of them through no fault of its own, is a bug.
    @Test func anAppendAfterATornTailDoesNotFuseOntoIt() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured("before"), to: url)
        try leaveATornFragment(Data(#"{"id":"dead"#.utf8), at: url)
        try JournalStore.append(captured("after"), to: url)

        let read = JournalStore.read(from: url)
        #expect(read.records.map(\.rawText) == ["before", "after"])
        #expect(read.damaged.count == 1, "the fragment is still the fragment, on its own line")
    }

    /// A damaged line can be removed, addressed by the bytes it holds.
    ///
    /// Every rewrite carries an undecodable line through untouched — deliberately, since it is
    /// the only copy of whatever it holds — which until now made it permanent: no screen could
    /// name it and no rule could match it, so it sat at the tail of the file for the life of the
    /// app, and the retention window that clears ordinary junk could not reach it either.
    @Test func aDamagedLineCanBeRemovedByItsBytes() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured(realBody), to: url)

        let fragment = Data(#"{"id":"deadbeef","pha"#.utf8)
        try leaveATornFragment(fragment, at: url)

        let removed = try JournalStore.removeDamaged(from: url) { $0 == fragment }

        #expect(removed == 1)
        let read = JournalStore.read(from: url)
        #expect(read.damaged.isEmpty)
        #expect(read.records.map(\.rawText) == [realBody])
    }

    /// A rule that decides about records never removes a line it cannot read.
    ///
    /// Every record-shaped caller is deciding about rows the ledger derived from a line, and
    /// nothing was ever derived from a line nothing could read. The retention purge is the one
    /// that matters: it runs on every foreground, and a version of it that swept damaged lines
    /// up would delete the evidence it exists to preserve.
    @Test func aRecordRuleNeverRemovesADamagedLine() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured("delete me"), to: url)

        let fragment = Data(#"{"id":"deadbeef","pha"#.utf8)
        try leaveATornFragment(fragment, at: url)

        let removed = try JournalStore.remove(from: url) { _ in true }

        #expect(removed == 1, "the record goes")
        #expect(try Data(contentsOf: url).range(of: fragment) != nil,
                "and the damaged bytes stay — no rule over records can speak for them")
    }

    /// The framing guard reads the file, so it has to cope with a file that is not there and one
    /// that is empty — the first append on a fresh install does both — and it must not add
    /// anything when the file is already framed.
    ///
    /// Asserted in newlines rather than in records, because that is where the bug would show:
    /// a check that always answers "not terminated" writes a stray blank line before every
    /// record, and every reader here ignores empty lines, so nothing else would ever notice.
    /// (It did, in the first draft: the check read the tail through a write-only descriptor.)
    @Test func appendingToANewJournalStillWorks() throws {
        let url = tempJournalURL()
        try JournalStore.append(captured("first"), to: url)
        #expect(JournalStore.readAll(from: url).map(\.rawText) == ["first"])

        try JournalStore.append(captured("second"), to: url)
        #expect(JournalStore.readAll(from: url).map(\.rawText) == ["first", "second"])

        let raw = try Data(contentsOf: url)
        #expect(raw.filter { $0 == 0x0A }.count == 2, "one newline per record, and no others")
        #expect(raw.last == 0x0A, "the file ends framed, so the next append has nothing to fix")
    }
}
