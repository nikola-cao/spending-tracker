//
//  CaptureHealthTests.swift
//  spending-trackerTests
//

import Foundation
import SwiftData
import Testing
@testable import spending_tracker

/// What the Diagnostics screen reports about the *journal itself*, and the deletion of a line
/// nothing can read.
///
/// Both exist because they are answers the app previously could not give. A damaged line was
/// dropped from every read, so it was invisible on every screen at once; a body that resolved to
/// nothing was counted only inside a `DrainResult` that nothing displayed. Silence is the failure
/// mode this file is about — an alert that is simply absent, with nothing able to say so.
@MainActor
struct CaptureHealthTests {

    private let trailer = " Msg&Data rates may apply. Reply STOP to cancel."

    private func charge(_ amount: String, _ merchant: String) -> String {
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $\(amount) at \(merchant).\(trailer)"
    }

    private func tempJournalURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "st5-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    private func makeStore() throws -> (ledger: LedgerStore, container: ModelContainer, url: URL) {
        let container = try ModelContainer(
            for: Schema([AlertEvent.self, Txn.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let url = tempJournalURL()
        return (LedgerStore(container: container, journalURL: url), container, url)
    }

    private func txns(_ container: ModelContainer) -> [Txn] {
        (try? container.mainContext.fetch(FetchDescriptor<Txn>())) ?? []
    }

    /// A captured line, recorded as written **here**: this process, this journal directory.
    /// Those two fields are what `foreignLines` compares, so a helper filling them with anything
    /// else would make every line in these tests look misdirected.
    @discardableResult
    private func appendCapture(
        _ body: String,
        note: String = "",
        processName: String? = nil,
        journalDirectory: String? = nil,
        to url: URL
    ) throws -> JournalRecord {
        let record = JournalRecord(
            id: UUID(),
            runID: UUID(),
            phase: JournalRecord.capturePhase,
            receivedAt: Date(),
            processName: processName ?? RuntimeFacts.processName(),
            bundleIdentifier: RuntimeFacts.bundleIdentifier(),
            isMainThread: false,
            charCount: body.count,
            utf8ByteCount: body.utf8.count,
            hasFidelityPrefix: body.hasPrefix("Fidelity"),
            containsRegisteredTrademark: body.contains("\u{00AE}"),
            mentionsFidelity: FidelityAlertHeuristic.mentionsFidelity(body),
            appGroupAvailable: RuntimeFacts.appGroupAvailable(),
            journalDirectory: journalDirectory ?? JournalLocation.directoryPath,
            rawText: body,
            note: note
        )
        try JournalStore.append(record, to: url)
        return record
    }

    /// Bytes with no trailing newline — what a kill mid-append leaves behind.
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

    /// The three states that used to be one number, or no number at all.
    ///
    /// Each is a different thing wrong, and each needs a different response: a damaged line is
    /// evidence that has to be looked at, a held body is the parser doing its job, and an empty
    /// invocation is the Shortcut handing over nothing.
    @Test func diagnosticsSeparateDamagedHeldAndEmpty() throws {
        let (ledger, _, url) = try makeStore()
        try appendCapture(charge("2.50", "BREEZE*00HS5MV"), to: url)
        try appendCapture("Your Uber code is 1234", to: url)
        try appendCapture("", note: "rejected: empty input", to: url)

        let fragment = Data(#"{"id":"deadbeef","pha"#.utf8)
        try leaveATornFragment(fragment, at: url)

        ledger.drain()
        let diag = ledger.diagnostics()

        #expect(diag.eventCount == 1, "only the charge is a ledger row")
        #expect(diag.transactionCount == 1)
        #expect(diag.journalLines == 3, "three lines decoded; the damaged one is not one of them")
        #expect(diag.damagedLines == 1)
        #expect(diag.damagedBytes == fragment.count)
        #expect(diag.heldLines == 1)
        #expect(diag.emptyInvocations == 1)
        #expect(diag.foreignLines == 0, "every line here says it was written by this app")
    }

    /// A line written somewhere else is counted, because that is the one failure that loses an
    /// alert with no other trace anywhere: the write succeeded, and it succeeded elsewhere.
    ///
    /// The fields are recorded on every line so that "always zero" can be checked rather than
    /// believed — which requires something to count them.
    @Test func aLineWrittenElsewhereIsCounted() throws {
        let (ledger, _, url) = try makeStore()
        try appendCapture(charge("2.50", "HERE"), to: url)
        try appendCapture(charge("3.50", "ELSEWHERE"),
                          processName: "shortcutsd",
                          journalDirectory: "/var/mobile/Containers/Data/Application/OTHER/Library/Application Support/Journal",
                          to: url)

        let diag = ledger.diagnostics()

        #expect(diag.foreignLines == 1)
        #expect(diag.journalLines == 2)
    }

    /// An empty invocation must not keep "Last captured" looking alive.
    ///
    /// It is the same rule as a manual entry: the figure answers "is the automation still
    /// capturing", and an invocation that carried nothing is a broken Message wiring rather than
    /// a capture. Left in, a broken wiring would hold the number fresh while the ledger quietly
    /// stopped growing.
    @Test func emptyInvocationsDoNotCountAsCapture() throws {
        let (ledger, _, url) = try makeStore()
        try appendCapture(charge("2.50", "REAL CAPTURE"), to: url)
        // Read back from the file rather than held in hand: the journal stores timestamps at
        // one-second resolution, so the in-memory value has more precision than any line does.
        let capturedAt = try #require(JournalStore.readAll(from: url).last?.receivedAt)

        // Later, and must still not win.
        try appendCapture("", note: "rejected: empty input", to: url)

        let diag = ledger.diagnostics()

        #expect(diag.lastCapture == capturedAt)
        #expect(diag.emptyInvocations == 1)
    }

    /// Deleting a damaged line removes the line and nothing else.
    ///
    /// The one deletion with only a journal half. The record beside it has to survive — the
    /// rewrite that removes one line is the moment every other line is at risk.
    @Test func deletingADamagedLineLeavesEveryRecordAndRow() throws {
        let (ledger, container, url) = try makeStore()
        try appendCapture(charge("2.50", "KEPT"), to: url)
        let fragment = Data(#"{"id":"deadbeef","pha"#.utf8)
        try leaveATornFragment(fragment, at: url)

        ledger.drain()
        #expect(txns(container).count == 1)

        let result = try ledger.deleteDamagedLine(fragment)

        #expect(result.lines == 1)
        #expect(result.rows == 0, "nothing was ever derived from a line nothing could read")
        #expect(result.saveError == nil)

        let read = JournalStore.read(from: url)
        #expect(read.damaged.isEmpty)
        #expect(read.records.count == 1)

        // And the transaction the surviving line recorded is still a transaction.
        ledger.drain()
        #expect(txns(container).count == 1)
        #expect(txns(container).first?.merchant == "KEPT")
    }

    /// Deleting bytes that are not there is not an error, and changes nothing.
    @Test func deletingADamagedLineThatIsNotThereChangesNothing() throws {
        let (ledger, _, url) = try makeStore()
        try appendCapture(charge("2.50", "KEPT"), to: url)
        let before = try Data(contentsOf: url)

        let result = try ledger.deleteDamagedLine(Data(#"{"id":"nope"#.utf8))

        #expect(result.lines == 0)
        #expect(try Data(contentsOf: url) == before)
    }
}
