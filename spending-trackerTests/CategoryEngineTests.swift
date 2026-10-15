//
//  CategoryEngineTests.swift
//  spending-trackerTests
//
//  The classification pass: what it asks about, what it writes down, and what it remembers when
//  the answer does not come.
//

import Foundation
import SwiftData
import Testing
@testable import spending_tracker

/// Answers on demand, and remembers what it was asked.
///
/// `@unchecked Sendable` with a lock rather than an actor: `CategoryClient` is `Sendable` and the
/// protocol's method is `async`, so a lock is the simplest thing that cannot deadlock against the
/// main actor the engine runs on.
private final class FakeClient: CategoryClient, @unchecked Sendable {

    typealias Handler = @Sendable ([CategoryRequest]) throws -> [String: String]

    private let lock = NSLock()
    private var seen: [[CategoryRequest]] = []
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    /// Answers every merchant the same way.
    static func answering(_ label: String) -> FakeClient {
        FakeClient { requests in
            Dictionary(uniqueKeysWithValues: requests.map { ($0.key, label) })
        }
    }

    static func failing(_ error: CategoryClientError) -> FakeClient {
        FakeClient { _ in throw error }
    }

    /// Every batch it was handed, in order.
    var requests: [[CategoryRequest]] { lock.withLock { seen } }

    /// Every merchant it was asked about, across every batch.
    var askedKeys: [String] { requests.flatMap { $0.map(\.key) } }

    func classify(_ requests: [CategoryRequest]) async throws -> [String: String] {
        lock.withLock { seen.append(requests) }
        return try handler(requests)
    }
}

/// Serialized, like `LedgerStoreTests`, and for a related reason: the retry schedule lives in
/// process-wide `UserDefaults`, so two of these running at once would be counting each other's
/// attempts.
@MainActor
@Suite(.serialized)
struct CategoryEngineTests {

    private let trailer = " Msg&Data rates may apply. Reply STOP to cancel."

    // MARK: - Fixtures

    private func charge(_ amount: String, _ merchant: String) -> String {
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $\(amount) "
            + "at \(merchant).\(trailer)"
    }

    private func makeStore() throws -> (ledger: LedgerStore, container: ModelContainer, url: URL) {
        let container = try ModelContainer(
            for: Schema([AlertEvent.self, Txn.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let url = FileManager.default.temporaryDirectory
            .appending(path: "cat-\(UUID().uuidString)", directoryHint: .isDirectory)
            .appending(path: "journal.jsonl", directoryHint: .notDirectory)
        return (LedgerStore(container: container, journalURL: url), container, url)
    }

    private func appendAlert(_ body: String, at receivedAt: Date = Date(), to url: URL) throws {
        let record = JournalRecord(
            id: UUID(), runID: UUID(), phase: JournalRecord.capturePhase, receivedAt: receivedAt,
            processName: "spending-tracker", bundleIdentifier: "com.nikola.spending-tracker",
            isMainThread: true, charCount: body.count, utf8ByteCount: body.utf8.count,
            hasFidelityPrefix: body.hasPrefix("Fidelity"),
            containsRegisteredTrademark: body.contains("\u{00AE}"),
            mentionsFidelity: FidelityAlertHeuristic.mentionsFidelity(body),
            appGroupAvailable: false, journalDirectory: url.deletingLastPathComponent().path,
            rawText: body, note: "")
        try JournalStore.append(record, to: url)
    }

    private func txns(_ container: ModelContainer) -> [Txn] {
        (try? container.mainContext.fetch(FetchDescriptor<Txn>())) ?? []
    }

    /// An engine with every safety net explicitly switched off. The default is what keeps a test
    /// off the network, so overriding it has to be written down at each use — which is the point.
    private func makeEngine(
        _ ledger: LedgerStore,
        client: CategoryClient?,
        now: @escaping () -> Date = Date.init
    ) -> CategoryEngine {
        CategoryEngine(
            ledger: ledger, now: now, clientProvider: { client }, isSuppressed: { false })
    }

    // MARK: - What it asks about

    @Test func itAsksAboutEveryMerchantWithNoAnswer() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        try appendAlert(charge("9.00", "CHICK-FIL-A"), to: url)
        ledger.drain()

        let client = FakeClient.answering("grocery")
        let engine = makeEngine(ledger, client: client)
        await engine.run()

        #expect(client.askedKeys.sorted() == ["CHICK FIL A", "WHOLE FOODS MKT"])
        #expect(txns(container).allSatisfy { $0.categoryRaw == "grocery" })
        #expect(txns(container).allSatisfy { $0.categorySourceRaw == "ai" })
        #expect(engine.outcome == .answered(2))
    }

    /// The whole reason the backlog is keyed on the merchant. Three cups of coffee must be one
    /// question, not three — and one of them being a repeat charge does not make it a different
    /// merchant.
    @Test func oneMerchantIsAskedAboutOnceHoweverManyTransactionsItHas() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        for amount in ["4.00", "4.50", "5.00"] {
            try appendAlert(charge(amount, "BREEZE*00HS5MV"), to: url)
        }
        ledger.drain()

        let client = FakeClient.answering("dining")
        await makeEngine(ledger, client: client).run()

        #expect(client.requests.count == 1)
        #expect(client.askedKeys == ["BREEZE"], "\(client.askedKeys)")
    }

    /// A merchant already answered for, whether by the model or by hand, is not waiting. Asking
    /// again would spend a request to be told what the journal already says.
    @Test func anAnsweredMerchantIsNotAskedAboutAgain() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let first = FakeClient.answering("grocery")
        await makeEngine(ledger, client: first).run()
        #expect(first.askedKeys == ["WHOLE FOODS MKT"])

        let second = FakeClient.answering("retail")
        await makeEngine(ledger, client: second).run()

        #expect(second.askedKeys.isEmpty, "it asked about a merchant it already had an answer for")
        #expect(txns(container).first?.categoryRaw == "grocery")
    }

    /// A row the user cleared by hand has been *answered* — with "no category". It is not waiting
    /// on the model, and re-asking would both waste a request and keep telling the user their
    /// decision was still pending.
    @Test func aRowTheUserClearedIsNotWaiting() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "AMAZON"), to: url)
        ledger.drain()

        let row = try #require(txns(container).first)
        try ledger.setCategory(row, label: nil)
        ledger.drain()

        let client = FakeClient.answering("retail")
        await makeEngine(ledger, client: client).run()

        #expect(client.askedKeys.isEmpty, "a row the user cleared was put back in the queue")
        #expect(txns(container).first?.categoryRaw == "")
    }

    /// Only a charge is spending. Asking about a card payoff could only produce a spending
    /// category for something that is not spending — and the descriptor of a Venmo row is
    /// somebody's name.
    @Test func paymentsAndDepositsAreNeverSent() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        try ledger.appendManual(
            kind: .payment, merchant: "AMEX PAYMENT", amount: "-825.77", date: nil, cardSuffix: "")
        try ledger.appendManual(
            kind: .deposit, merchant: "ZELLE FROM SAM", amount: "25.00", date: nil, cardSuffix: "")
        ledger.drain()

        let client = FakeClient.answering("miscellaneous")
        await makeEngine(ledger, client: client).run()

        #expect(client.askedKeys.isEmpty, "\(client.askedKeys)")
    }

    @Test func nothingWaitingLeavesItIdle() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        ledger.drain()

        let client = FakeClient.answering("retail")
        let engine = makeEngine(ledger, client: client)
        await engine.run()

        #expect(client.requests.isEmpty)
        #expect(engine.outcome == .idle)
    }

    // MARK: - Batching

    /// **The retry filter is applied before the limit, not after it.**
    ///
    /// Taking the newest few hundred merchants and then dropping the throttled ones means a wall
    /// of merchants in backoff hides every due merchant behind them — the pass returns nothing,
    /// does nothing, and the backlog the user is staring at never moves. Counting only what is
    /// wanted is what makes the limit mean "the newest N that can actually be asked about".
    @Test func theLimitCountsOnlyMerchantsThatCanBeAskedAbout() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        // Distinct arrival times, deliberately. Appended in a loop they would share a timestamp,
        // and "newest first" would then be arbitrary among the ties — so the test would be
        // asserting an order the store never promised.
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        for index in 0..<6 {
            try appendAlert(
                charge("1.00", "MERCHANT\(index)"),
                at: start.addingTimeInterval(Double(index)),
                to: url)
        }
        ledger.drain()

        // Unfiltered, the window fills with the newest and the older ones are unreachable.
        let newest = ledger.uncategorizedMerchants(limit: 3).map(\.key)
        #expect(Set(newest) == ["MERCHANT5", "MERCHANT4", "MERCHANT3"], "\(newest)")

        // Filtered to the oldest three — the ones a backoff would be hiding — they come back.
        let due = ledger.uncategorizedMerchants(limit: 3) {
            ["MERCHANT0", "MERCHANT1", "MERCHANT2"].contains($0)
        }
        #expect(Set(due.map(\.key)) == ["MERCHANT0", "MERCHANT1", "MERCHANT2"],
                "\(due.map(\.key))")
    }

    @Test func merchantsAreSentInBatches() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        // `MERCHANT0` rather than `STORE 10`: a standalone number is a store code to the
        // normaliser, and forty of them would collapse into one merchant.
        for index in 0..<(DeepSeekClient.batchLimit + 5) {
            try appendAlert(charge("1.00", "MERCHANT\(index)"), to: url)
        }
        ledger.drain()

        let client = FakeClient.answering("retail")
        await makeEngine(ledger, client: client).run()

        #expect(client.requests.count == 2)
        #expect(client.requests.first?.count == DeepSeekClient.batchLimit)
        #expect(client.requests.last?.count == 5)
    }

    // MARK: - When the answer does not come

    @Test func aTransientFailureWritesNothingAndHoldsTheRetry() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let clock = Clock()
        let failing = FakeClient.failing(.transient("no network"))
        let engine = makeEngine(ledger, client: failing, now: { clock.now })
        await engine.run()

        #expect(engine.outcome == .failed("no network"))
        #expect(txns(container).allSatisfy { $0.categoryRaw.isEmpty }, "a failure wrote a category")

        // The merchant waits, and is asked again once the wait is over.
        #expect(!CategorizationBackoff.isDue("WHOLE FOODS MKT", now: clock.now))

        let working = FakeClient.answering("grocery")
        let later = makeEngine(ledger, client: working, now: { clock.advance(by: 31) })
        await later.run()

        #expect(working.askedKeys == ["WHOLE FOODS MKT"])
        #expect(txns(container).first?.categoryRaw == "grocery")
    }

    /// A refused key is not evidence about any merchant. Counting it would march the whole ledger
    /// toward the daily ceiling over a typo — and the fix would not bring any of them back early.
    @Test func aBlockedRunStopsAndDoesNotHoldAnythingAgainstAMerchant() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let clock = Clock()
        let engine = makeEngine(
            ledger, client: FakeClient.failing(.blocked("the key was refused")), now: { clock.now })
        await engine.run()

        #expect(engine.outcome == .blocked("the key was refused"))
        #expect(CategorizationBackoff.isDue("WHOLE FOODS MKT", now: clock.now),
                "a blocked run must leave the retry schedule untouched")

        // And the next pass asks straight away, with nothing to wait out.
        let working = FakeClient.answering("grocery")
        await makeEngine(ledger, client: working, now: { clock.now }).run()
        #expect(working.askedKeys == ["WHOLE FOODS MKT"])
    }

    /// One unreadable merchant must not cost the other thirty-nine their answer.
    @Test func aDeclinedMerchantDoesNotTakeTheBatchDown() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        try appendAlert(charge("9.00", "CHICK-FIL-A"), to: url)
        ledger.drain()

        let clock = Clock()
        // Answers only the first, which is how a declined merchant looks: absent from the reply.
        let client = FakeClient { requests in
            requests.first.map { [$0.key: "grocery"] } ?? [:]
        }
        let engine = makeEngine(ledger, client: client, now: { clock.now })
        await engine.run()

        let rows = txns(container)
        #expect(rows.filter { $0.categoryRaw == "grocery" }.count == 1)
        #expect(rows.filter { $0.categoryRaw.isEmpty }.count == 1)

        // The one that was declined waits; the one that was answered does not.
        let answered = try #require(rows.first { $0.categoryRaw == "grocery" })
        let declined = try #require(rows.first { $0.categoryRaw.isEmpty })
        #expect(CategorizationBackoff.isDue(MerchantKey.normalize(answered.merchant),
                                             now: clock.now))
        #expect(!CategorizationBackoff.isDue(MerchantKey.normalize(declined.merchant),
                                             now: clock.now))
    }

    @Test func everyMerchantDeclinedIsSaidDifferentlyFromNothingToDo() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let engine = makeEngine(ledger, client: FakeClient { _ in [:] })
        await engine.run()

        #expect(engine.outcome == .declined)
    }

    // MARK: - The guards

    @Test func withNoClientNothingIsAsked() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, container, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let engine = makeEngine(ledger, client: nil)
        await engine.run()

        #expect(engine.outcome == .idle)
        #expect(txns(container).allSatisfy { $0.categoryRaw.isEmpty })
    }

    /// The switch that keeps the test suite off the network, at the level it actually operates.
    @Test func suppressionStopsThePass() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let client = FakeClient.answering("grocery")
        let engine = CategoryEngine(
            ledger: ledger, clientProvider: { client }, isSuppressed: { true })
        await engine.run()

        #expect(client.requests.isEmpty, "a suppressed engine made a request")
    }

    /// And that the switch is actually *on* here, which is the part that could quietly stop
    /// being true.
    ///
    /// This test runs inside the app binary with XCTest loaded — precisely the condition the
    /// check exists for. Asserting it means a change that broke the detection fails here, rather
    /// than the suite silently gaining the ability to put live requests on the wire.
    @Test func thePassIsSuppressedInsideTheTestProcess() {
        #expect(!ProcessInfo.processInfo.arguments.contains(CategoryEngine.suppressArgument),
                "this test only proves anything if the argument is not the reason")
        #expect(CategoryEngine.isSuppressed,
                "XCTest is loaded in this process, so the engine should be suppressed")
    }

    /// The tripwire for the one hole the XCTest check cannot cover.
    ///
    /// A UI test launches the app as a separate process that does not link XCTest, so that
    /// process is only suppressed because the UI suite passes the argument — and it has to spell
    /// the string out, because a UI-test bundle cannot import this module. Renaming the constant,
    /// or changing its value, would therefore unprotect the UI suite **silently**. This fails
    /// first, and points at the literal in `spending_trackerUITests.swift`.
    @Test func theSuppressionArgumentIsNotRenamed() {
        #expect(CategoryEngine.suppressArgument == "-disableCategorization")
    }

    @Test func tryingAgainNowForgetsTheWait() async throws {
        CategorizationBackoff.clearAll()
        let (ledger, _, url) = try makeStore()
        try appendAlert(charge("42.00", "WHOLE FOODS MKT"), to: url)
        ledger.drain()

        let clock = Clock()
        await makeEngine(
            ledger, client: FakeClient.failing(.transient("no network")), now: { clock.now }
        ).run()

        // Well inside the backoff, so an ordinary pass would do nothing.
        let working = FakeClient.answering("grocery")
        let engine = makeEngine(ledger, client: working, now: { clock.advance(by: 1) })
        await engine.tryAgainNow()

        #expect(working.askedKeys == ["WHOLE FOODS MKT"])
    }
}

/// A clock the test moves by hand, so a backoff can be waited out without waiting.
@MainActor
private final class Clock {
    private(set) var now = Date(timeIntervalSince1970: 1_780_000_000)

    @discardableResult
    func advance(by seconds: TimeInterval) -> Date {
        now = now.addingTimeInterval(seconds)
        return now
    }
}
