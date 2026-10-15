//
//  CategoryEngine.swift
//  spending-tracker
//
//  Asking the classifier about the merchants nobody has answered for.
//

import Foundation
import Network
import Observation

/// Runs the classification pass.
///
/// **Deliberately not part of `drain()`.** The drain is `@MainActor` and fully synchronous with
/// no `await` anywhere below it, which is what stops its three call sites from interleaving — and
/// it runs inside every unit test's process. A network call in there would break the first
/// property and put a request on the wire during the test run.
///
/// **Nothing here can affect capture.** A charge is journalled, drained and on screen before this
/// is ever reached, and a pass that fails writes nothing at all. The worst a bad network can do
/// is leave rows saying they have no category yet — which is what they already said.
///
/// **The backlog is a question, not a queue.** Every pass asks the store which charges nothing has
/// answered for, so nothing is stored between passes and nothing has to survive the rebuild that
/// empties the store. A merchant leaves the backlog by having one more journal line, or by its row
/// being deleted.
@MainActor
@Observable
final class CategoryEngine {

    /// What the last pass did, for the Diagnostics screen.
    enum Outcome: Equatable {
        case idle
        /// Waiting on an answer, or about to be.
        case running
        /// Merchants filed, and how many.
        case answered(Int)
        /// The service replied, and nothing in the reply could be used — every merchant declined.
        case declined
        /// The call failed. Nothing was written, and nothing about any merchant was held against
        /// it beyond the retry schedule.
        case failed(String)
        /// The key or the request was refused, so the run stopped without touching the schedule.
        /// The user has something to fix.
        case blocked(String)
    }

    /// A launch argument that keeps a pass from ever being made.
    ///
    /// For the test runs, which execute inside this app's own binary with this app's own keychain
    /// and defaults. With no key nothing would be sent anyway — but "would not" is a weaker
    /// promise than "cannot", and a suite that can reach the network is a suite that fails on a
    /// train.
    static let suppressArgument = "-disableCategorization"

    static var isSuppressed: Bool {
        // By argument, and under XCTest. The unit tests run in this process with XCTest loaded,
        // so a key left in a simulator's keychain by hand would otherwise be enough to put a real
        // request on the wire mid-suite.
        ProcessInfo.processInfo.arguments.contains(suppressArgument)
            || NSClassFromString("XCTestCase") != nil
    }

    /// How many merchants travel in one request.
    static let batchSize = DeepSeekClient.batchLimit

    /// How many requests one pass will make.
    ///
    /// Bounded on purpose, and the bound is stated on the Diagnostics screen rather than left
    /// implicit: a first pass over a long history is thousands of merchants, and one that tried
    /// to do them all at once would hold the radio open and be killed mid-flight. Whatever is
    /// left over is simply asked again at the next foreground, because the backlog is a question.
    static let maxRequestsPerRun = 8

    /// How many waiting merchants are looked at before the retry schedule is applied.
    ///
    /// Larger than one run's worth, so that merchants sitting out a backoff cannot hide the ones
    /// behind them that are due. A personal ledger will not approach this.
    static let candidateLimit = 500

    private let ledger: LedgerStore

    /// `@MainActor` rather than a plain closure, because the default reads the keychain and this
    /// class is main-actor isolated. Left unannotated, passing the default would be a conversion
    /// that drops the actor — a warning today and an error under the Swift 6 language mode, which
    /// this target is one setting away from.
    private let clientProvider: @MainActor () -> CategoryClient?
    private let now: () -> Date

    /// Injectable so a test can run a pass at all. The default is the safety net, and it has to
    /// be overridden *explicitly* to make a request — which is the property that matters: no test
    /// can reach the network by forgetting something.
    private let isSuppressed: @MainActor () -> Bool

    private(set) var outcome: Outcome = .idle
    private var isRunning = false

    private var monitor: NWPathMonitor?
    private var hasObservedPath = false
    private var wasReachable = false

    init(
        ledger: LedgerStore,
        now: @escaping () -> Date = Date.init,
        clientProvider: @escaping @MainActor () -> CategoryClient? = CategoryEngine.clientFromKeychain,
        isSuppressed: @escaping @MainActor () -> Bool = { CategoryEngine.isSuppressed }
    ) {
        self.ledger = ledger
        self.now = now
        self.clientProvider = clientProvider
        self.isSuppressed = isSuppressed
    }

    /// Built from the keychain on every pass, so a key pasted into the settings sheet takes
    /// effect on the very next one with nothing to wire up — and so **no key means no client, no
    /// request, and no URL ever formed**. Not configuring the classifier is a supported way to
    /// use this app, not a degraded one.
    static func clientFromKeychain() -> CategoryClient? {
        guard let key = CategoryKeychain.apiKey else { return nil }
        return DeepSeekClient(apiKey: key)
    }

    /// The most merchants one pass will ask about, for the screen that has to say so.
    static var merchantsPerRun: Int { batchSize * maxRequestsPerRun }

    // MARK: - Running

    /// One pass. Safe to call on every foreground: it does nothing without a key, and returns
    /// immediately if a pass is already under way.
    func run() async {
        guard !isSuppressed() else { return }

        // Single-flight. The triggers are independent — a foreground, a pull-to-refresh and a
        // network coming back can all land together — and two passes at once would ask the same
        // questions twice and race to write the same lines.
        guard !isRunning else { return }
        guard let client = clientProvider() else { return }

        let timestamp = now()
        let due = ledger.uncategorizedMerchants(limit: Self.candidateLimit)
            .filter { CategorizationBackoff.isDue($0.key, now: timestamp) }
        guard !due.isEmpty else {
            outcome = .idle
            return
        }

        isRunning = true
        outcome = .running
        defer { isRunning = false }

        var answered = 0
        var declined = 0
        let budget = min(due.count, Self.merchantsPerRun)

        for start in stride(from: 0, to: budget, by: Self.batchSize) {
            let batch = Array(due[start..<min(start + Self.batchSize, budget)])

            do {
                let labels = try await client.classify(batch)
                let result = write(labels, in: batch)
                answered += result.written
                declined += result.unanswered.count

                // Counting a declined merchant as an attempt, because it *was* one and nothing
                // came of it. Without that, a merchant this service cannot read would be asked
                // about on every single pass, forever, at full rate.
                CategorizationBackoff.record(result.unanswered, at: timestamp)

                if let failure = result.failure {
                    outcome = .failed(failure)
                    return
                }
            } catch let error as CategoryClientError {
                switch error {
                case .blocked(let reason):
                    // Stop the whole run, and remember nothing against any merchant: the key or
                    // the request was refused, so nothing about them was ever tested. Fixing the
                    // key and asking again resumes from where this stopped.
                    outcome = .blocked(reason)
                    return

                case .transient(let reason):
                    CategorizationBackoff.record(batch.map(\.key), at: timestamp)
                    outcome = .failed(reason)
                    return
                }
            } catch {
                CategorizationBackoff.record(batch.map(\.key), at: timestamp)
                outcome = .failed(error.localizedDescription)
                return
            }
        }

        if answered > 0 {
            outcome = .answered(answered)
        } else {
            // Every merchant in the run was declined. Worth saying differently from "nothing to
            // do", because it is the state a wrong prompt or a wrong model would leave behind.
            outcome = declined > 0 ? .declined : .idle
        }
    }

    /// Forgets every wait and asks again now — the escape hatch on Diagnostics, for a user who
    /// has just fixed their network and does not want to pull-to-refresh until it takes.
    func tryAgainNow() async {
        CategorizationBackoff.clearAll()
        await run()
    }

    /// Writes one rule per answered merchant, then drains once.
    ///
    /// A journal failure is returned rather than thrown, so the caller can tell the merchants
    /// that got no answer — including the ones whose write failed — from the ones that were
    /// answered. Throwing would lose that split, and the merchants already written would be
    /// charged a failed attempt they did not have.
    private func write(
        _ labels: [String: String],
        in batch: [CategoryRequest]
    ) -> (written: Int, unanswered: [String], failure: String?) {
        var written = 0
        var unanswered: [String] = []
        var failure: String?

        for request in batch {
            guard let label = labels[request.key] else {
                unanswered.append(request.key)
                continue
            }

            do {
                try ledger.setMerchantRule(
                    merchant: request.merchant, label: label, source: .ai)
            } catch {
                failure = error.localizedDescription
                unanswered.append(request.key)
                continue
            }

            CategorizationBackoff.clear([request.key])
            written += 1
        }

        // One drain for the whole reply. The drain re-reads and re-parses the journal, and doing
        // that once per answer would be forty passes for one batch of forty.
        if written > 0 { ledger.drain() }
        return (written, unanswered, failure)
    }

    // MARK: - Coming back online

    /// Watches for the network returning while the app is open.
    ///
    /// The second trigger, and the cheap one: no entitlement, no `Info.plist` entry, nothing for
    /// iOS to decide. It exists because waiting for the next foreground is plainly unnecessary
    /// when the user is *looking at the app* as the signal comes back.
    ///
    /// **Only the transition into reachable.** A path update also fires for things that change
    /// nothing — a handover from wifi to cellular, a VPN coming up — and treating each as an
    /// invitation would spend a request per handover. `run()` is single-flight besides, so a
    /// flapping network cannot stack passes up.
    func startWatchingConnectivity() {
        guard !isSuppressed(), monitor == nil else { return }

        let monitor = NWPathMonitor()
        self.monitor = monitor
        // Cleared so the first reading is a baseline rather than a transition. Without it the
        // pass would fire the moment the app opened, from a path that had "changed" only in the
        // sense of having just been observed.
        hasObservedPath = false

        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                self?.observe(reachable: reachable)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.nikola.spending-tracker.connectivity"))
    }

    func stopWatchingConnectivity() {
        // Cancelled and dropped rather than paused: an `NWPathMonitor` cannot be restarted after
        // `cancel()`, so keeping one would mean a monitor that silently stops watching the
        // second time the view appears.
        monitor?.cancel()
        monitor = nil
        hasObservedPath = false
    }

    private func observe(reachable: Bool) {
        defer {
            hasObservedPath = true
            wasReachable = reachable
        }
        guard hasObservedPath, reachable, !wasReachable else { return }
        Task { await run() }
    }
}
