//
//  LedgerStore.swift
//  spending-tracker
//
//  Turns the raw journal into ledger rows.
//

import CryptoKit
import Foundation
import SwiftData

/// Drains the append-only journal into SwiftData, and compacts the journal as it goes.
///
/// **The App Intent is deliberately not involved.** It keeps writing raw text to the journal
/// exactly as it did in Stage 1, and this runs in the app when it becomes active. Three
/// reasons that is the better design, not a shortcut:
///
/// 1. The intent is the one component *proven on real hardware* — a locked phone in a pocket,
///    iOS 27, `allowedExecutionTargets = .main`. Nothing downstream needs to touch it, so
///    nothing downstream can break it.
/// 2. Writing to the ledger at capture time buys nothing. The UI only exists while the app is
///    open, so a row written at 2pm and drained at 6pm is indistinguishable from one written
///    at 2pm — you could not have seen it either way.
/// 3. It removes three real hazards at once: `@Dependency` (a non-optional generic with no
///    default init), SwiftData writes from a non-main actor, and a second process opening the
///    same store.
///
/// Adding a second source (Amex email) required no change to this shape at all: a source is a
/// parser, and the journal does not care where a body came from.
///
/// **Only charges reach the ledger; everything else is held in the journal for a week.**
/// The automations also capture a merchant's own confirmation email for a purchase already
/// recorded, statement notices, and OTPs. None of that is ever a ledger row — but it is not
/// discarded on arrival either. Holding it costs nothing in the store and preserves the
/// recovery path: a retained body is re-parsed on every drain, so a charge that starts being
/// recognised within the week is picked up with no special handling. See `nonChargeRetention`.
@MainActor
final class LedgerStore {

    struct DrainResult: Equatable {
        var recordsRead = 0
        var eventsAdded = 0
        var transactionsAdded = 0
        /// Bodies that resolved to no charge, and so were recorded nowhere.
        var notCharges = 0
        /// Journal lines dropped for not being charges and outliving the retention window.
        var journalLinesDropped = 0
        /// Non-nil when the store refused the write. Surfaced in the UI rather than
        /// swallowed: a silent save failure renders a complete-looking ledger that is not on
        /// disk and vanishes at relaunch.
        var saveError: String?
    }

    private let container: ModelContainer
    private let journalURL: URL

    /// What is in the bank, as the journal states it. See `bankBalance(from:)`.
    ///
    /// Read-only to everyone else because it is *derived*: there is nothing to set. Changing
    /// it means writing a line, which is what `setBankBalance` and a deposit both do.
    private(set) var bankBalanceMinor = 0

    /// What is owed on the cards, as the journal states it.
    ///
    /// Derived exactly like the bank balance and read-only for the same reason. The difference
    /// is what feeds it: the bank moves for deposits and payments, this moves for charges and
    /// payments — a charge is owed on a card and never touches the bank until it is paid.
    ///
    /// Positive means owed, which is the sign the rows themselves carry, so a `Card |` line and
    /// the summing of the charges it supersedes cannot disagree about which way round it goes.
    private(set) var cardBalanceMinor = 0

    init(container: ModelContainer, journalURL: URL = JournalLocation.fileURL) {
        self.container = container
        self.journalURL = journalURL
    }

    /// Two charges that look identical this close together may be the same event arriving
    /// twice. Flagged, never merged — see `Txn.possibleDuplicate`.
    private static let duplicateWindow: TimeInterval = 300

    /// Reads the journal, records any charge not already recorded, and drops the rest.
    /// Idempotent, so it is safe to call on every foreground.
    ///
    /// Fully synchronous, and therefore non-reentrant by construction: there is no `await`
    /// anywhere below, so the three call sites (`.task`, `scenePhase`, pull-to-refresh) cannot
    /// interleave on the main actor.
    @discardableResult
    func drain() -> DrainResult {
        var result = DrainResult()

        let context = container.mainContext
        let records = JournalStore.readAll(from: journalURL)
        result.recordsRead = records.count

        let instructions = Self.instructions(from: records)
        refreshBankBalance(derived: instructions.bank, records: records)
        // No adoption branch and no legacy handover, unlike the bank above: a card balance has
        // only ever lived in the journal, so there is nothing from an earlier version of the app
        // to carry over — and therefore no way for a stale value to reappear once its last line
        // is deleted.
        cardBalanceMinor = instructions.card ?? 0

        if !records.isEmpty {
            ingest(records, into: context, result: &result)
        }

        // After the ingest, never before: an edit replaces a row that has to exist first. On a
        // rebuild the original line is replayed into a row and this lands on top of it, in the
        // same pass — which is what makes an edit survive a rebuild with no extra state.
        applyEdits(instructions.edits, into: context)

        // Last, and after the edits, because it reads the merchant those edits may just have
        // changed. A merchant rule is matched on what the row *says*, so classifying against the
        // pre-edit spelling would file a corrected row under the old name's category.
        applyCategories(instructions.categories, into: context)

        do {
            try context.save()
        } catch {
            // Roll back so the UI cannot render rows that are not on disk, and report it.
            // The journal is untouched, so the next drain retries from scratch.
            context.rollback()
            result.saveError = error.localizedDescription
            return result
        }

        // The purge runs only AFTER the store has accepted the write. If the save failed the
        // journal is the only copy of anything, so nothing may be dropped from it.
        result.journalLinesDropped = purgeExpired(now: Date())
        return result
    }

    // MARK: - The bank balance

    /// Sets the bank balance by writing a line, so a rebuild can restore it.
    ///
    /// The number is an assertion about the world rather than a movement of money, which is
    /// why it is a line of its own instead of an enormous deposit: a deposit says "this
    /// arrived", a balance says "this is what is there", and only the second is allowed to
    /// disagree with everything before it.
    func setBankBalance(_ minor: Int) throws {
        try JournalStore.append(
            .diagnostic(
                runID: UUID(),
                phase: JournalRecord.capturePhase,
                raw: JournalInstructionParser.composeBankBalance(minor),
                note: JournalRecord.manualMarker
            ),
            to: journalURL
        )
        drain()
    }

    /// Sets the card balance by writing a line, so a rebuild can restore it.
    ///
    /// The same shape as `setBankBalance` and for the same reasons. The number is an assertion
    /// about the world rather than a movement of money, so it is a line of its own and not an
    /// enormous charge; and the store is derived, so a figure not written here is gone at the
    /// next rebuild with nothing to restore it from.
    ///
    /// Positive means owed, matching the sign the charge rows already carry. A card in credit is
    /// a real state and takes a leading minus.
    func setCardBalance(_ minor: Int) throws {
        try JournalStore.append(
            .diagnostic(
                runID: UUID(),
                phase: JournalRecord.capturePhase,
                raw: JournalInstructionParser.composeCardBalance(minor),
                note: JournalRecord.manualMarker
            ),
            to: journalURL
        )
        drain()
    }

    /// The balance the journal describes: the last value set, plus every deposit since.
    ///
    /// **Derived, never stored.** It used to live in `UserDefaults`, which meant it survived a
    /// rebuild only by accident — the journal could not restore it, so a schema change would
    /// have rebuilt the ledger and left the balance stale and unexplainable.
    ///
    /// Folded in journal order, which is the only order there is: the journal is append-only
    /// and position is meaningful, so "the last balance set" and "the deposits after it" are
    /// well defined without a single timestamp being read. Deleting a deposit's line therefore
    /// gives the money back with no extra bookkeeping — the fold simply sees one fewer.
    /// Every category the journal asserts, in the only order there is.
    ///
    /// Two tiers, kept apart rather than merged, because they are different claims: a line about
    /// one transaction says "this purchase", and a line about a merchant says "this shop". The
    /// resolution between them is `resolve`, and the ranking it implements — specificity first,
    /// person before model — is the whole reason they are not one dictionary.
    ///
    /// Within a tier the **last line in the file wins**, which needs no ordering field: file
    /// position is the order, the journal is append-only, and a rebuild replays the same bytes
    /// in the same sequence. The same append-and-supersede idiom the balance fold uses.
    struct CategoryDecisions: Equatable {

        /// A category some line put on one row. `label == nil` is an explicit clear rather than
        /// a missing value — see `JournalInstruction.Category.label`.
        struct Assignment: Equatable {
            let label: String?
            let source: JournalInstruction.Source
        }

        /// Keyed by occurrence key — `runID#index`, the same name every edit and deletion uses.
        var overrides: [String: Assignment] = [:]

        /// Keyed by `MerchantKey.normalize`. Split by who decided, so that a rule the model
        /// wrote can never displace one a person wrote, whatever order they arrived in.
        var userRules: [String: String] = [:]
        var aiRules: [String: String] = [:]

        mutating func record(_ rule: JournalInstruction.MerchantCategory) {
            // A rule naming a merchant with no key would match every row whose key is also
            // empty. Refused here rather than only at the parser, because this is the last
            // place that can see it before it becomes a category on the whole ledger.
            let key = MerchantKey.normalize(rule.merchant)
            guard !key.isEmpty else { return }

            switch rule.source {
            case .user: userRules[key] = rule.label
            case .ai: aiRules[key] = rule.label
            }
        }

        /// What the journal decides about one row.
        enum Decision: Equatable {
            /// A line named this row. A nil label is an **explicit clear** — an answer about the
            /// absence of a category, which is why it is not the same case as `unanswered`.
            case named(label: String?, source: JournalInstruction.Source)

            /// A rule stands for this row's merchant.
            case rule(label: String, source: JournalInstruction.Source)

            /// Nothing in the journal speaks for this row.
            case unanswered

            /// The category to show, or nil when there is none.
            var label: String? {
                // Written as separate arms rather than one combined pattern: `named` carries a
                // `String?` and `rule` a `String`, and a shared binding would have to pick one
                // of them to be.
                switch self {
                case .named(let label, _): return label
                case .rule(let label, _): return label
                case .unanswered: return nil
                }
            }

            /// Who decided it, or nil when there is no category to have a source.
            ///
            /// A clear reports no source: there is no category, and claiming one had a decider
            /// would be a claim about a value that is not there.
            var source: JournalInstruction.Source? {
                switch self {
                case .named(_, let source), .rule(_, let source): return source
                case .unanswered: return nil
                }
            }

            /// Whether the journal has answered for this row at all, category or not.
            ///
            /// The question the classifier's backlog is asked. A row the user cleared by hand
            /// **has** been answered — it is not waiting on the model — and treating it as
            /// outstanding would spend a request per pass to be told what the row already says,
            /// and would keep telling the user their decision was pending.
            var isAnswered: Bool { self != .unanswered }
        }

        /// What one row is filed under, or why it is not.
        ///
        /// **First match wins, and the order is the whole design.**
        ///
        /// 1. a line naming this transaction, whatever else exists — including one that clears
        ///    it, which stops here rather than falling through;
        /// 2. a rule a person wrote for this merchant;
        /// 3. a rule the model wrote for this merchant;
        /// 4. nothing.
        ///
        /// Specificity beats generality (1 before 2) so that "apply this to every Whole Foods"
        /// cannot rewrite the one row the user has already spoken about individually. A person
        /// beats the model (2 before 3) so that an answer arriving later cannot overwrite a
        /// decision already made by hand — which matters because the model's answers arrive
        /// asynchronously and *after* the fact, and a category the user set that quietly changed
        /// under them would be the worst failure this feature could have.
        func decide(occurrenceKey: String?, merchant: String) -> Decision {
            if let occurrenceKey, let assignment = overrides[occurrenceKey] {
                return .named(label: assignment.label, source: assignment.source)
            }

            let key = MerchantKey.normalize(merchant)
            guard !key.isEmpty else { return .unanswered }
            if let label = userRules[key] { return .rule(label: label, source: .user) }
            if let label = aiRules[key] { return .rule(label: label, source: .ai) }
            return .unanswered
        }
    }

    /// Everything the journal says beyond "here is a row", gathered in one pass.
    ///
    /// The balances, the edits and the categories are collected together because all of them need
    /// the same walk in the same order, and the order is the whole point: a line means what it
    /// means because of where it sits relative to the lines it supersedes. Separate passes would
    /// each have to remember that, and would eventually stop agreeing about it.
    ///
    /// The two balances are folded in one pass rather than two, because the pass is the same
    /// and only the predicate differs — and two passes over the same records is two chances for
    /// them to disagree about which lines counted.
    private static func instructions(
        from records: [JournalRecord]
    ) -> (bank: Int?, card: Int?, edits: [JournalInstruction.Edit], categories: CategoryDecisions) {
        var seenInvocations = Set<UUID>()

        // `isAppWritten` is carried alongside the body because **a line a source sent is
        // evidence, never a command**. Instruction lines are the app writing to its own journal
        // and are stamped `manualMarker`; a captured alert is written by the intent with an empty
        // note. Without the distinction, a message whose text happened to begin `Bank |` or
        // `Category |` would be honoured as an instruction — a body from outside deciding the
        // user's bank balance, or filing a category, by nothing more than how it happens to
        // start. Every instruction writer has used the marker since the balance line was first
        // journalled, so nothing legitimate is excluded by asking.
        let lines = records.compactMap { record -> (runID: UUID, body: String, isAppWritten: Bool)? in
            let body = record.trimmedBody
            guard !body.isEmpty else { return nil }
            // Collapsed by invocation, exactly as `ingest` collapses it — and this was a latent
            // bug until the card balance arrived. One invocation used to write an `enter` and a
            // `result` line carrying the SAME body, and this walk re-parses every line it is
            // handed, so a charge captured back then is summed TWICE unless the pair is
            // collapsed. A card balance reading double the feed it sits above is precisely the
            // plausible-looking wrong total this ledger is built to make impossible. It went
            // unnoticed because the only kinds the fold used to sum were deposits and payments,
            // which postdate the pair entirely.
            guard seenInvocations.insert(record.runID).inserted else { return nil }
            return (record.runID, body, record.note == JournalRecord.manualMarker)
        }

        // The edits and the categories are gathered first, because an edit may supersede a
        // deposit that sits *earlier* in the file and the balance below has to move by the
        // amount that was edited to. Folding in a single pass would read the original and
        // quietly ignore the correction.
        var edits: [JournalInstruction.Edit] = []
        var categories = CategoryDecisions()
        for line in lines where line.isAppWritten {
            switch JournalInstructionParser.parse(line.body) {
            case .edit(let edit)?:
                edits.append(edit)
            case .category(let category)?:
                categories.overrides[category.occurrenceKey] = CategoryDecisions.Assignment(
                    label: category.label, source: category.source)
            case .merchantCategory(let rule)?:
                categories.record(rule)
            default:
                continue
            }
        }
        // Last one wins, matching `applyEdits`, which replays them in order.
        let editedAmounts = Dictionary(
            edits.map { ($0.occurrenceKey, $0.amountMinor) }, uniquingKeysWith: { _, last in last })

        var bank: Int?
        var card: Int?
        for line in lines {
            // A captured body is never read as an instruction, so it always takes the `nil` arm
            // below — which is what it is. See the note on `isAppWritten` above.
            let instruction = line.isAppWritten
                ? JournalInstructionParser.parse(line.body)
                : nil

            switch instruction {
            case .setBankBalance(let minor)?:
                bank = minor
            case .setCardBalance(let minor)?:
                card = minor
            case .edit?, .category?, .merchantCategory?:
                // Instructions that say nothing about either balance. Every one is named
                // explicitly rather than caught by a `default`, and that is deliberate: the `nil`
                // arm below assumes the body is a message a source sent, and an unrecognised
                // instruction reaching it would be run through the parsers, where a mis-parse
                // becomes a fabricated charge against a balance. Adding a case here is what the
                // compiler makes you do instead.
                continue
            case nil:
                // Not an instruction, so it is an alert — and each kind moves the position it
                // actually moves. A charge is owed on a card and never touches the bank until it
                // is paid; a deposit is the bank and never a card; a payment is the one movement
                // that is both, settling a card with money out of the bank.
                for (index, alert) in AlertParsers.parseAll(line.body).enumerated() {
                    // Keyed exactly as the ingest keys it, so an edit reaches the right line.
                    // The lookup is shared rather than repeated per position because one edit
                    // can move both — editing a payment's amount moves the bank and the card by
                    // the same corrected figure, which is the whole reason it is one value here.
                    let key = "\(line.runID.uuidString)#\(index)"
                    let amount = editedAmounts[key] ?? alert.amountMinor
                    if alert.affectsBank { bank = (bank ?? 0) + amount }
                    if alert.affectsCard { card = (card ?? 0) + amount }
                }
            }
        }
        return (bank, card, edits, categories)
    }

    /// Replays every edit, in journal order, onto the rows they name.
    ///
    /// Re-applied in full on every drain rather than tracked as done, which costs one pass and
    /// buys the property that matters: the result is a pure function of the journal. There is
    /// no "already applied" flag to get out of step with the store after a rebuild, a deletion,
    /// or a crash between the two.
    private func applyEdits(_ edits: [JournalInstruction.Edit], into context: ModelContext) {
        guard !edits.isEmpty else { return }

        for edit in edits {
            guard let txn = transaction(for: edit.occurrenceKey, in: context) else { continue }

            txn.amountMinor = edit.amountMinor
            txn.merchant = edit.merchant
            txn.cardSuffix = edit.cardSuffix

            // The date is set whole or cleared whole — never merged. A charge that had a real
            // time loses it here: the edited value is a date with no time, so the row stops
            // claiming a time of day nobody stated, and reads "Purchased <date>" like the Amex
            // rows do. Clearing it falls back to arrival, exactly as an omitted date does
            // everywhere else.
            if let occurredAt = edit.occurredAt {
                txn.occurredAt = occurredAt
                txn.occurredAtIsFromMessage = true
            } else {
                txn.occurredAt = txn.receivedAt
                txn.occurredAtIsFromMessage = false
            }
        }
    }

    /// Lands the journal's category decisions on the rows.
    ///
    /// Re-applied in full on every drain rather than tracked as done — the same shape and the
    /// same reason as `applyEdits`. The result is a pure function of the journal, so there is no
    /// "already classified" flag to fall out of step with the store after a rebuild, a deletion,
    /// or a crash between the two, and undoing a category is simply having one fewer line.
    ///
    /// **Writes only where the value actually changes.** The store is not rewritten on every
    /// foreground for the rows that already agree, which keeps this pass free of the save churn
    /// and of the `possibleDuplicate` style of accidental side effect.
    ///
    /// Non-charges are skipped rather than cleared: a payment or a deposit is not uncategorized,
    /// it is *not categorizable*, and writing `""` onto one on every drain would be work done
    /// forever to say nothing.
    private func applyCategories(_ decisions: CategoryDecisions, into context: ModelContext) {
        let txns = (try? context.fetch(FetchDescriptor<Txn>())) ?? []

        for txn in txns where txn.isCategorizable {
            let decision = decisions.decide(
                occurrenceKey: txn.occurrenceKey, merchant: txn.merchant)
            let label = decision.label ?? ""
            let source = decision.source?.rawValue ?? ""

            guard txn.categoryRaw != label || txn.categorySourceRaw != source else { continue }
            txn.categoryRaw = label
            txn.categorySourceRaw = source
        }
    }

    // MARK: - What is waiting to be classified

    /// The merchants waiting for an answer, newest first, one entry per merchant.
    ///
    /// **Derived, never stored.** The backlog is the set of charges the journal has not answered
    /// for, recomputed from scratch whenever it is asked. A stored queue could not survive the
    /// schema change that empties the store, and the only place that outlives one is the journal
    /// — which is where a category already lives. So the queue is a question, and a merchant
    /// leaves it by having one more line, or by the row being deleted.
    ///
    /// Deduped by `MerchantKey`, because a merchant is the unit the model is asked about: one
    /// entry per transaction would spend a request per coffee, and every one of them would be
    /// the same question. The spelling carried is the one on the newest row, which is the one
    /// the user is most likely looking at.
    ///
    /// A row the user cleared by hand is **not** waiting. See `CategoryDecisions.Decision`.
    ///
    /// - Parameter isWanted: Whether a waiting merchant should be counted and returned at all.
    ///   Applied **before** the limit, and that order is the point. Filtering afterwards — take
    ///   the newest five hundred, then drop the ones in a backoff — means a wall of throttled
    ///   merchants hides every due one behind them, and the pass does nothing while the user
    ///   watches a backlog that will not move. Counting only what is wanted makes the limit mean
    ///   "the newest N that can actually be asked about".
    func uncategorizedMerchants(
        limit: Int,
        where isWanted: (String) -> Bool = { _ in true }
    ) -> [CategoryRequest] {
        let decisions = Self.instructions(
            from: JournalStore.readAll(from: journalURL)).categories

        let descriptor = FetchDescriptor<Txn>(
            sortBy: [SortDescriptor(\Txn.receivedAt, order: .reverse)])
        let txns = (try? container.mainContext.fetch(descriptor)) ?? []

        var seen = Set<String>()
        var waiting: [CategoryRequest] = []
        for txn in txns where txn.isCategorizable {
            guard !decisions.decide(
                occurrenceKey: txn.occurrenceKey, merchant: txn.merchant).isAnswered
            else { continue }

            let key = MerchantKey.normalize(txn.merchant)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            guard isWanted(key) else { continue }

            waiting.append(CategoryRequest(key: key, merchant: txn.merchant))
            if waiting.count >= limit { break }
        }
        return waiting
    }

    /// The figures the Diagnostics screen shows for the classifier.
    ///
    /// Counted here rather than stored anywhere, for the same reason everything else on that
    /// screen is: they are all restatements of the journal, and a remembered count is a count
    /// that can be wrong.
    struct CategorizationCounts: Equatable {
        var charges = 0
        var categorized = 0
        var byPerson = 0
        var byModel = 0
        /// Charges with nothing decided for them yet.
        var waiting = 0
        /// Distinct merchants among those, which is what a pass would actually ask about.
        var merchantsWaiting = 0
        var userRules = 0
        var modelRules = 0
    }

    func categorizationCounts() -> CategorizationCounts {
        var result = CategorizationCounts()
        let decisions = Self.instructions(
            from: JournalStore.readAll(from: journalURL)).categories
        result.userRules = decisions.userRules.count
        result.modelRules = decisions.aiRules.count

        let txns = (try? container.mainContext.fetch(FetchDescriptor<Txn>())) ?? []
        var waitingKeys = Set<String>()

        for txn in txns where txn.isCategorizable {
            result.charges += 1

            if txn.hasCategory {
                result.categorized += 1
                if txn.categoryWasSetByPerson { result.byPerson += 1 } else { result.byModel += 1 }
            }

            guard !decisions.decide(
                occurrenceKey: txn.occurrenceKey, merchant: txn.merchant).isAnswered
            else { continue }

            result.waiting += 1
            let key = MerchantKey.normalize(txn.merchant)
            if !key.isEmpty { waitingKeys.insert(key) }
        }

        result.merchantsWaiting = waitingKeys.count
        return result
    }

    /// The row an occurrence key names, or nil when nothing is stored under it.
    private func transaction(for occurrenceKey: String, in context: ModelContext) -> Txn? {
        let parts = occurrenceKey.split(separator: "#", maxSplits: 1)
        guard parts.count == 2,
              let runID = UUID(uuidString: String(parts[0])),
              let matchIndex = Int(parts[1])
        else { return nil }

        let descriptor = FetchDescriptor<AlertEvent>(
            predicate: #Predicate { $0.runID == runID && $0.matchIndex == matchIndex }
        )
        return (try? context.fetch(descriptor))?.first?.transaction
    }

    /// Adopts a balance set before any of this was journalled, once.
    ///
    /// Without it the one number the user typed themselves would be the one thing a rebuild
    /// could not restore — exactly the bug journalling it is meant to fix. It is written to the
    /// journal first and only cleared from `UserDefaults` afterwards, so a failed write leaves
    /// the value where it was rather than losing it.
    private func refreshBankBalance(derived: Int?, records: [JournalRecord]) {
        if let derived {
            bankBalanceMinor = derived
            // The journal already says what the balance is, so the pre-journal `UserDefaults`
            // value can never be adopted now — clear it while we are here.
            //
            // This is not tidiness. Adoption is attempted only when the fold derives NOTHING
            // (`derived` is nil), and on a device that already had a deposit when the balance
            // moved into the journal, this branch is taken instead and the legacy value was
            // never cleared. Delete that last deposit — which the Raw journal now offers — and
            // the fold derives nothing on the next drain, at which point the stale value is
            // adopted and written into the journal as a balance nobody set, restating the Bank
            // figure to a number from a previous version of the app.
            BankBalance.clearLegacyStoredValue()
            return
        }

        if let legacy = BankBalance.legacyStoredValue {
            do {
                try JournalStore.append(
                    .diagnostic(
                        runID: UUID(),
                        phase: JournalRecord.capturePhase,
                        raw: JournalInstructionParser.composeBankBalance(legacy),
                        note: JournalRecord.manualMarker
                    ),
                    to: journalURL
                )
            } catch {
                // Left in `UserDefaults` deliberately: the next drain tries again.
                bankBalanceMinor = legacy
                return
            }
            BankBalance.clearLegacyStoredValue()
            bankBalanceMinor = legacy
            return
        }

        bankBalanceMinor = 0
    }

    private func ingest(
        _ records: [JournalRecord],
        into context: ModelContext,
        result: inout DrainResult
    ) {
        var known = knownOccurrences(in: context)

        // One invocation writes an `enter` and a `result` line carrying the same body. For a
        // charge the occurrence key collapses the pair, but a body that is NOT a charge records
        // no key at all — so without this the pair would be parsed, counted and compacted as
        // two separate things.
        var seenInvocations = Set<UUID>()

        for record in records {
            let body = record.trimmedBody
            guard !body.isEmpty else { continue }
            guard seenInvocations.insert(record.runID).inserted else { continue }

            // Only real movements of money are recorded — a charge or a deposit. The index is
            // the position in the FULL parse rather than in the filtered list, so an
            // occurrence key stays stable if a body's mix of entries and non-entries changes.
            let entries = AlertParsers.parseAll(body)
                .enumerated()
                .filter { $0.element.isLedgerEntry }

            guard !entries.isEmpty else {
                result.notCharges += 1
                continue
            }

            for (index, alert) in entries {
                // Keyed on the INVOCATION, not the body. See `AlertEvent.occurrenceKey` for
                // why: a body is not unique per transaction, so keying on it silently dropped
                // every repeat charge — a monthly subscription would be recorded once, ever.
                let key = "\(record.runID.uuidString)#\(index)"
                guard !known.contains(key) else { continue }
                known.insert(key)

                let event = AlertEvent(
                    receivedAt: record.receivedAt,
                    runID: record.runID,
                    matchIndex: index,
                    body: body,
                    contentHash: Self.contentHash(body),
                    parseState: .parsed,
                    parserVersion: AlertParsers.version
                )
                context.insert(event)
                result.eventsAdded += 1

                let txn = Txn(from: alert, receivedAt: record.receivedAt)
                // Computed BEFORE the row is inserted or wired up, so the fetch cannot see it.
                txn.possibleDuplicate = hasNearbyEqual(txn, in: context)
                context.insert(txn)

                txn.event = event
                event.transaction = txn
                result.transactionsAdded += 1
            }
        }
    }

    /// How long a body that resolved to no charge is kept before being dropped.
    ///
    /// Charges are kept forever. Everything else — a merchant's own confirmation email for a
    /// purchase already recorded, a statement notice, an OTP — is held for a week and then
    /// purged.
    ///
    /// The window is what preserves the recovery path. A retained body is re-parsed on every
    /// drain, so a charge that starts being recognised within the week is picked up normally,
    /// with no special handling. Past that it is gone, which is the accepted cost of not
    /// carrying junk indefinitely.
    static let nonChargeRetention: TimeInterval = 7 * 24 * 60 * 60

    /// Drops journal lines that resolved to no charge and have outlived the retention window.
    ///
    /// Asked as "which line may go" rather than "which lines to keep", so the decision is a
    /// pure function of one record and can be made **inside** `JournalStore.remove`'s critical
    /// section. That is the point of the shape: the records the drain read at its start are
    /// already stale by the time the purge runs — a whole ingest and a save later — so
    /// rebuilding the file from that list would write away any alert that arrived meanwhile.
    /// That alert can be a real charge.
    ///
    /// This is the only place in the app that deliberately discards captured text.
    private func purgeExpired(now: Date) -> Int {
        let cutoff = now.addingTimeInterval(-Self.nonChargeRetention)
        // A purge that cannot run is harmless — the same lines go on a later drain — so the
        // error is deliberately swallowed here, unlike in a deletion the user asked for.
        return (try? JournalStore.remove(from: journalURL) { record in
            let body = record.trimmedBody
            guard !body.isEmpty else { return record.receivedAt <= cutoff }
            // A charge or a deposit is kept forever, whenever it arrived: the ledger row it
            // produced has to stay derivable from this line for the rest of the app's life.
            if AlertParsers.parseAll(body).contains(where: \.isLedgerEntry) { return false }
            // An instruction too, and for the same reason — the bank balance is rebuilt by
            // folding over these lines, so dropping one would quietly restate the balance. A
            // category line is the same argument with a sharper edge: it is a decision the user
            // made, and nothing else on disk holds it.
            //
            // Asked by leading token rather than by whether it parses. A line whose *format* this
            // version cannot read is exactly the one that must not be thrown away — it was
            // written by the app, it holds a value, and no screen can address it either. Judge it
            // on readability and it ages out after a week like a merchant's receipt.
            if JournalInstructionParser.hasInstructionPrefix(body) { return false }
            // Anything else — including an empty body — survives only inside the window.
            return record.receivedAt <= cutoff
        }) ?? 0
    }

    // MARK: - Manual entry

    enum ManualEntryError: LocalizedError {
        case empty

        var errorDescription: String? {
            switch self {
            case .empty: "There is nothing to record."
            }
        }
    }

    /// Records a message the user typed or pasted.
    ///
    /// Appends to the **journal**, not the store, deliberately: the text then takes the exact
    /// path a captured alert uses, so it is durable, replayable, and cannot drift from the
    /// real ingest. It also means the whole pipeline can be exercised end to end without
    /// waiting for a real purchase.
    @discardableResult
    func appendManualEntry(_ text: String) throws -> UUID {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw ManualEntryError.empty }

        let runID = UUID()
        try JournalStore.append(
            .diagnostic(runID: runID, phase: JournalRecord.capturePhase, raw: body,
                        note: JournalRecord.manualMarker),
            to: journalURL
        )
        return runID
    }

    /// Records a charge or a deposit a person typed into the form.
    ///
    /// Composed into the canonical line and journalled, so it takes the same path as a
    /// captured charge — same drain, same retention, same deletion behaviour — and can be
    /// re-read on any later launch. See `ManualEntryParser` for the format and the reason it
    /// is a text line rather than a row written straight into the store.
    ///
    /// A deposit is journalled for the same reason a charge is, and it is not a technicality:
    /// the store is rebuilt from the journal whenever the schema changes, so a deposit that
    /// was never written here would be gone at the next rebuild with nothing to restore it
    /// from. `cardSuffix` must be empty for a deposit.
    ///
    /// `date` and `cardSuffix` are optional: only a merchant and an amount are required. A nil
    /// date leaves the entry with no time of its own, so the ledger falls back to the moment it
    /// was made — exactly what it does for a Fidelity charge alert, which carries no date.
    @discardableResult
    func appendManual(
        kind: ParsedAlert.Kind,
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) throws -> UUID {
        try appendManualEntry(
            ManualEntryParser.compose(
                kind: kind,
                merchant: merchant,
                amount: amount,
                date: date,
                cardSuffix: cardSuffix
            )
        )
    }

    enum EditError: LocalizedError {
        case notAddressable

        var errorDescription: String? {
            switch self {
            case .notAddressable:
                "This row has no journal line to edit, so the change could not be recorded."
            }
        }
    }

    /// Changes a row by appending a line that supersedes the one it came from.
    ///
    /// Appended rather than rewritten. The journal is append-only, and for a captured charge
    /// the text is evidence: overwriting a Fidelity body because the merchant was mistyped
    /// would destroy the only record of what the card actually said. The original stays and
    /// this line names it by occurrence key, so a rebuild replays both and lands in the same
    /// place.
    ///
    /// The edit does not go through the parser registry. It carries no source text, only the
    /// values the form ended up with, and reading it back through `ManualEntryParser` would
    /// make it a second manual entry rather than a change to an existing one.
    @discardableResult
    func edit(
        _ txn: Txn,
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) throws -> UUID {
        // A row with no event has no key, so nothing could ever point back at it. Refusing is
        // the honest answer; writing an edit that addresses nothing would look like a save.
        guard let occurrenceKey = txn.occurrenceKey else { throw EditError.notAddressable }

        let runID = UUID()
        try JournalStore.append(
            .diagnostic(
                runID: runID,
                phase: JournalRecord.capturePhase,
                raw: JournalInstructionParser.composeEdit(
                    occurrenceKey: occurrenceKey,
                    merchant: merchant,
                    amount: amount,
                    date: date,
                    cardSuffix: cardSuffix
                ),
                note: JournalRecord.manualMarker
            ),
            to: journalURL
        )
        return runID
    }

    enum CategoryError: LocalizedError {
        case notAddressable
        case emptyMerchant
        case badLabel(String)

        var errorDescription: String? {
            switch self {
            case .notAddressable:
                "This transaction has no journal line to attach a category to, so nothing was saved."
            case .emptyMerchant:
                "There is no merchant to remember this for."
            case .badLabel(let label):
                "\"\(label)\" is not something this app can write down as a category."
            }
        }
    }

    /// Files one transaction under a category, or clears it when `label` is nil.
    ///
    /// Appended, never rewritten — and here that is not only about protecting evidence. The
    /// row's category is a *projection* of the journal, recomputed on every drain, so a line is
    /// not a record of a change that was made: it is the whole of the value. There is nowhere
    /// else to put it that a rebuild would not empty.
    ///
    /// A nil label writes an **explicit clear** rather than writing nothing, which is the
    /// difference between "this row has no category and no rule may give it one" and "this row
    /// says nothing, so the rule for its merchant applies". Without the distinction, a single
    /// row could never be taken back out of a rule the user set on purpose.
    ///
    /// The caller drains afterwards; this only writes the line, exactly as `edit` does.
    @discardableResult
    func setCategory(_ txn: Txn, label: String?) throws -> UUID {
        guard let occurrenceKey = txn.occurrenceKey else { throw CategoryError.notAddressable }
        if let label, !SpendingCategory.isWellFormed(label) { throw CategoryError.badLabel(label) }

        let runID = UUID()
        try JournalStore.append(
            .diagnostic(
                runID: runID,
                phase: JournalRecord.capturePhase,
                raw: JournalInstructionParser.composeCategory(
                    occurrenceKey: occurrenceKey, label: label, source: .user),
                note: JournalRecord.manualMarker
            ),
            to: journalURL
        )
        return runID
    }

    /// Files everything from one merchant under a category.
    ///
    /// `merchant` must be the descriptor **as a row spells it**, never a normalised key — the
    /// key is recomputed from this string on every read, so storing a key would orphan the rule
    /// the moment the normaliser changed. Callers pass `txn.merchant`.
    ///
    /// The line is one merchant's answer, which is why a monthly subscription costs a single
    /// request for the life of the app rather than one a month. Rows the user has filed
    /// individually keep their own category: `CategoryDecisions.resolve` ranks a line about one
    /// transaction above a line about the shop, so this cannot rewrite a decision already made.
    @discardableResult
    func setMerchantRule(
        merchant: String,
        label: String,
        source: JournalInstruction.Source = .user
    ) throws -> UUID {
        let merchant = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !merchant.isEmpty else { throw CategoryError.emptyMerchant }
        guard SpendingCategory.isWellFormed(label) else { throw CategoryError.badLabel(label) }

        let runID = UUID()
        try JournalStore.append(
            .diagnostic(
                runID: runID,
                phase: JournalRecord.capturePhase,
                raw: JournalInstructionParser.composeMerchantCategory(
                    merchant: merchant, label: label, source: source),
                note: JournalRecord.manualMarker
            ),
            to: journalURL
        )
        return runID
    }

    /// The card suffixes seen so far, for the manual-entry picker.
    ///
    /// Newest first, so the card used most recently is the first option. Reads from `Txn`
    /// rather than from the form's own history, which means it reflects what was actually
    /// captured — including cards only ever seen through the automations.
    func knownCardSuffixes() -> [String] {
        let descriptor = FetchDescriptor<Txn>(
            sortBy: [SortDescriptor(\Txn.receivedAt, order: .reverse)]
        )
        let txns = (try? container.mainContext.fetch(descriptor)) ?? []

        var seen = Set<String>()
        var result: [String] = []
        for txn in txns where !txn.cardSuffix.isEmpty {
            if seen.insert(txn.cardSuffix).inserted { result.append(txn.cardSuffix) }
        }
        return result
    }

    // MARK: - Deleting

    /// What a deletion removed, and whether the store half of it succeeded.
    struct JournalDeletion: Equatable {
        /// Journal lines removed. Zero is ordinary — it means nothing matched.
        var lines = 0
        /// Ledger rows removed: one `AlertEvent` per recorded alert, plus any row that had none.
        var rows = 0
        /// Non-nil when the journal was rewritten but the store refused the delete. The rows
        /// are still in the store and still on screen; the user finishes from the feed.
        var saveError: String?
    }

    /// Removes charges, and the journal lines they came from.
    ///
    /// **The journal edit is not optional.** The store is derived: the drain re-reads the
    /// journal on every foreground and recreates any invocation it does not already know
    /// about, so deleting only the row would have it reappear moments later.
    ///
    /// The journal is written FIRST, and that order matters. If the journal edit lands and the
    /// store delete fails, the row is still on screen and the user can simply delete it again.
    /// The reverse order fails the other way: the row disappears, then silently comes back on
    /// the next drain, which is both confusing and looks like a bug in the app rather than a
    /// failed write.
    ///
    /// Throws when the journal could not be rewritten at all — the one case where nothing has
    /// happened yet, so the caller can simply try again. A store save that fails *after* the
    /// rewrite is a different thing and is reported in `JournalDeletion.saveError` instead of
    /// thrown, because the deletion is by then half done and the caller needs to know which
    /// half.
    ///
    /// Deleting by row removes the whole **invocation**, not only the row that was tapped. The
    /// event carries the invocation identity and a single message can carry more than one
    /// alert, so a sibling row goes with it. That is deliberate: the journal line belongs to
    /// the invocation, and a sibling left behind would be a row whose evidence is gone — one a
    /// rebuild would drop with no explanation.
    @discardableResult
    func delete(_ txns: [Txn]) throws -> JournalDeletion {
        guard !txns.isEmpty else { return JournalDeletion() }

        var runIDs = Set<UUID>()
        var orphans: [Txn] = []
        for txn in txns {
            if let event = txn.event {
                runIDs.insert(event.runID)
            } else {
                // Should not happen — every charge is derived from an event — but a row that
                // somehow has none must still be deletable.
                orphans.append(txn)
            }
        }

        return try deleteInvocations(runIDs: runIDs, orphanTxns: orphans)
    }

    /// Deletes one line of the raw journal, and whatever the ledger derived from it.
    ///
    /// The entry point the Raw journal screen uses. It takes the `JournalRecord` rather than a
    /// bare `runID` so the screen never has to know the identity rule, and it removes **every**
    /// line of that record's invocation: the invocation is the unit the store dedups on
    /// (`AlertEvent.occurrenceKey`), and a journal written before single-line capture holds an
    /// `enter`/`result` pair under one `runID`. Removing only the line that was tapped would
    /// leave its twin to rebuild the row on the very next drain.
    ///
    /// A line that produced nothing — a merchant's own confirmation, an OTP, a statement
    /// notice — has no rows to remove and simply goes. That case is most of the reason the
    /// feature exists: those lines have no ledger row to swipe, so until now they could not be
    /// deleted from the app at all.
    @discardableResult
    func deleteJournalLine(_ record: JournalRecord) throws -> JournalDeletion {
        // An edit is an instruction *about* a row rather than a row, which makes it the one case
        // where removing the line is not the whole job. `applyEdits` only applies the edits it
        // can still see and `ingest` never revisits a row it already knows, so taking the line
        // away on its own would leave the store holding the edited values while the journal,
        // replayed, no longer says them — the screen and a rebuild would disagree, and the
        // confirmation's promise that the row reverts would simply be false.
        //
        // So the row it named goes too, and the next drain re-derives it from the original line
        // and replays whatever edits are still standing. That much is the same property
        // everything here rests on: the store is a pure function of the journal.
        if case .instruction(.edit(let edit)) = record.outcome {
            return try deleteEditLine(record, named: edit.occurrenceKey)
        }
        return try deleteInvocations(runIDs: [record.runID])
    }

    /// Deletes a line the current schema cannot read back.
    ///
    /// The one deletion with **only** a journal half, because there is nothing else it could
    /// have: a line nothing can decode produced no `AlertEvent` and no `Txn`, so no row is
    /// removed and no figure moves. `rows` is therefore always zero and the caller should say so
    /// rather than print a count.
    ///
    /// It exists because the alternative is worse than it sounds. Every rewrite carries an
    /// undecodable line through untouched — deliberately, since it is the only copy of whatever
    /// it holds — but that made it **permanently undeletable**: no screen could address it, and
    /// no rule could match it, so it sat at the tail of the file for the life of the app while
    /// the retention window that clears ordinary junk could not touch it either.
    ///
    /// Addressed by its bytes rather than by position, for the same reason everything else here
    /// is addressed by identity: a rewrite renumbers every line in the file, so an index is a
    /// name that changes under the thing it names. Two damaged lines with identical bytes are
    /// identical evidence, so removing both is the honest reading of "remove this line".
    @discardableResult
    func deleteDamagedLine(_ bytes: Data) throws -> JournalDeletion {
        var result = JournalDeletion()
        result.lines = try JournalStore.removeDamaged(from: journalURL) { damaged in
            damaged == bytes
        }
        return result
    }

    /// Deletes an edit line and the row it named.
    ///
    /// **Store first, and only here.** Everywhere else the journal is written first, because a
    /// row that vanishes and then reappears on the next drain reads as the app undoing the
    /// delete. This case is the exception because its store half is not a removal at all: the
    /// row is dropped purely so the drain will re-derive it from the original line. That makes
    /// a failure self-healing in this direction and *only* in this direction —
    ///
    ///  - the save fails: nothing has happened, the line is still in the journal, the user
    ///    retries;
    ///  - the save lands and the journal write then fails: the edit line survives, so the next
    ///    drain re-ingests the original line and replays the edit, and the row comes back
    ///    exactly as it was.
    ///
    /// The other order fails the one way nothing repairs. The line would already be gone, the
    /// save would roll back, and the store would keep the edited values with no edit left in the
    /// journal to explain them — permanently, since `ingest` skips a row it already knows and
    /// `applyEdits` has nothing left to apply. The screen would disagree with a rebuild forever.
    private func deleteEditLine(_ record: JournalRecord, named key: String) throws -> JournalDeletion {
        var result = JournalDeletion()

        let stored = (try? container.mainContext.fetch(FetchDescriptor<AlertEvent>())) ?? []
        let storeOutcome = deleteStoredRows(stored.filter { $0.occurrenceKey == key })
        result.rows = storeOutcome.rows
        result.saveError = storeOutcome.saveError

        // Refused the write, so nothing was deleted and the line stays where it is.
        guard result.saveError == nil else { return result }

        // A throw here leaves the row deleted and the line in place, which the next drain
        // repairs by replaying the line. So the delete did not happen — say so, rather than
        // reporting a half-state the app will quietly undo.
        result.lines = try JournalStore.remove(from: journalURL) { $0.runID == record.runID }
        return result
    }

    /// How many ledger rows a journal line is responsible for — for the confirmation copy.
    ///
    /// Read from the **store**, never by re-parsing the text. The two can disagree: a body that
    /// parsed when it was ingested and no longer does still owns its row, because the drain
    /// only ever adds. A confirmation that promised "nothing in the ledger changes" and then
    /// deleted that row would be wrong in exactly the place the user is being asked to trust.
    func rowsRecorded(by record: JournalRecord) -> Int {
        let context = container.mainContext
        let events = (try? context.fetch(FetchDescriptor<AlertEvent>())) ?? []
        return events.filter { $0.runID == record.runID }.count
    }

    /// The ordinary deletion path: journal first, then the store.
    ///
    /// The store half is keyed on `runID` rather than on the rows handed in, so a deletion can
    /// never leave behind a row whose journal line has gone.
    @discardableResult
    private func deleteInvocations(
        runIDs: Set<UUID>,
        orphanTxns: [Txn] = []
    ) throws -> JournalDeletion {
        var result = JournalDeletion()
        guard !runIDs.isEmpty || !orphanTxns.isEmpty else { return result }

        if !runIDs.isEmpty {
            // The whole read-filter-rename runs inside `JournalStore`, under one lock hold.
            // A throw here means the journal is untouched and so is the store.
            //
            // A category line goes with the rows it names. It is addressed by occurrence key, so
            // once the invocation it points at is gone the line can never match anything again —
            // while instruction lines are kept forever, so it would sit in the file for the life
            // of the app, re-read on every drain, doing nothing. Leaving it costs nothing today
            // and is unfixable tomorrow: no screen shows it beside the row it used to name, and
            // nothing would ever decide on its own that it was safe to remove.
            result.lines = try JournalStore.remove(from: journalURL) { record in
                if runIDs.contains(record.runID) { return true }
                return Self.namesOne(of: runIDs, record)
            }
        }

        let context = container.mainContext
        // Fetched whole and filtered here rather than through a `#Predicate`: the journal is
        // small, the drain already reads every event to build its occurrence set, and a
        // predicate capturing a `Set<UUID>` is a needless fight with the macro.
        let stored = runIDs.isEmpty
            ? []
            : ((try? context.fetch(FetchDescriptor<AlertEvent>())) ?? [])
                .filter { runIDs.contains($0.runID) }

        let outcome = deleteStoredRows(stored, and: orphanTxns)
        result.rows = outcome.rows
        result.saveError = outcome.saveError
        return result
    }

    /// Whether this line is a category naming a row whose invocation is being deleted.
    ///
    /// Parsed rather than pattern-matched on the text. The occurrence key's shape belongs to
    /// `JournalInstructionParser`, and a second reader of it here would be a second place for it
    /// to drift out of agreement with the writer.
    ///
    /// `nonisolated` because it is called from inside `JournalStore.remove`'s critical section,
    /// which holds a lock and is deliberately not on the main actor. It touches no store state,
    /// so there is nothing for the isolation to protect.
    nonisolated private static func namesOne(of runIDs: Set<UUID>, _ record: JournalRecord) -> Bool {
        guard case .category(let category)? = JournalInstructionParser.parse(record.trimmedBody)
        else { return false }
        guard let uuid = category.occurrenceKey
            .split(separator: "#", maxSplits: 1).first
            .flatMap({ UUID(uuidString: String($0)) })
        else { return false }

        return runIDs.contains(uuid)
    }

    /// Deletes rows and saves, or rolls back so what is on screen is what is on disk.
    ///
    /// The one implementation of the store half, shared by both orderings above. A rollback
    /// here always means *nothing* was deleted from the store, and the caller reports it rather
    /// than swallowing it — a swipe whose row stays put has to look like a failure, not like the
    /// app undoing the delete.
    private func deleteStoredRows(
        _ events: [AlertEvent],
        and orphanTxns: [Txn] = []
    ) -> (rows: Int, saveError: String?) {
        guard !events.isEmpty || !orphanTxns.isEmpty else { return (0, nil) }

        let context = container.mainContext
        var rows = 0
        for event in events {
            // The event carries the relationship; deleting it cascades to its transaction.
            context.delete(event)
            rows += 1
        }
        for txn in orphanTxns {
            context.delete(txn)
            rows += 1
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            return (0, error.localizedDescription)
        }
        return (rows, nil)
    }

    // MARK: - Diagnostics

    struct Diagnostics: Equatable {
        var eventCount = 0
        var transactionCount = 0
        var parserVersion = 0
        var journalLines = 0
        var journalBytes = 0

        /// Lines in the file that could not be read back at all. Non-zero is the one state in
        /// which a transaction can be missing with no other trace on any screen — which is
        /// exactly why the count is here rather than left to a `print` somewhere.
        var damagedLines = 0
        var damagedBytes = 0

        /// Lines written by a process, or into a container, other than this one. Every line
        /// records both, so this is a claim that can be checked rather than believed — and
        /// should always be zero.
        var foreignLines = 0

        /// Bodies still inside the retention window that resolved to no movement of money —
        /// a merchant's own receipt, an OTP, a statement notice.
        var heldLines = 0

        /// Invocations that arrived carrying nothing. Not the same as a failure to *read* a
        /// body: this is the Shortcut handing over an empty string, which the intent journals
        /// on purpose so that "ran with empty input" stays distinguishable from "never ran".
        var emptyInvocations = 0

        var lastCapture: Date?
        var lastManualEntry: Date?
    }

    /// Everything needed to answer "is capture still working, and is the ledger keeping up".
    func diagnostics() -> Diagnostics {
        var result = Diagnostics()
        let context = container.mainContext

        result.eventCount = (try? context.fetchCount(FetchDescriptor<AlertEvent>())) ?? 0
        result.transactionCount = (try? context.fetchCount(FetchDescriptor<Txn>())) ?? 0
        result.parserVersion = AlertParsers.version

        // `read`, not `readAll`: the damaged lines are half of what this screen is for, and the
        // records-only reader cannot report them.
        let read = JournalStore.read(from: journalURL)
        let records = read.records
        result.journalLines = records.count
        result.damagedLines = read.damaged.count
        result.damagedBytes = read.damagedByteCount

        let here = JournalLocation.directoryPath
        let process = RuntimeFacts.processName()
        result.foreignLines = records.filter {
            $0.journalDirectory != here || $0.processName != process
        }.count

        // Re-parsed here rather than remembered anywhere. `Txn` holds only movements of money,
        // so a body that resolved to nothing is stored nowhere else — and what it means is a
        // function of the parser, which changes.
        for record in records {
            switch record.outcome {
            case .nothing: result.heldLines += 1
            case .empty: result.emptyInvocations += 1
            case .movement, .instruction: break
            }
        }

        // Manual entries are excluded: this answers "is the AUTOMATION still capturing". So are
        // empty invocations, and for the same reason — an empty body means the automation ran
        // and handed over nothing, which is a broken Message wiring rather than a capture. Left
        // in, a broken wiring would keep this figure looking fresh while nothing was being
        // captured at all, and it is the only warning the 7-day signing expiry gives. The count
        // of them is on the screen beside it, where it says what happened.
        result.lastCapture = records.last {
            $0.note != JournalRecord.manualMarker && !$0.trimmedBody.isEmpty
        }?.receivedAt
        result.lastManualEntry = records.last {
            $0.note == JournalRecord.manualMarker
                && !JournalInstructionParser.hasInstructionPrefix($0.trimmedBody)
        }?.receivedAt

        result.journalBytes = (try? FileManager.default
            .attributesOfItem(atPath: journalURL.path(percentEncoded: false))[.size] as? Int) ?? 0
        return result
    }

    // MARK: - Internals

    private func knownOccurrences(in context: ModelContext) -> Set<String> {
        let events = (try? context.fetch(FetchDescriptor<AlertEvent>())) ?? []
        return Set(events.map(\.occurrenceKey))
    }

    /// True when a same-looking charge already exists within `duplicateWindow`.
    ///
    /// Windowed on purpose. Two identical amounts at the same merchant *hours* apart are two
    /// real purchases — the same coffee bought twice this month — and flagging those would
    /// train the flag to be ignored. This is the only place a repeated charge is treated as
    /// suspicious, and it never discards: both rows are kept and one is labelled.
    ///
    /// Note this compares `merchant` byte-for-byte, which is only meaningful *within* a
    /// source. Amex sends an enriched merchant name and Fidelity sends a truncated issuer
    /// descriptor, so the two can never be equal — two different tools for two different
    /// problems, and mixing them would be a bug.
    ///
    /// The window is measured on `receivedAt`, not `occurredAt`. A redelivery arrives seconds
    /// after the original, which is the thing being detected. Measuring on `occurredAt` would
    /// be wrong for Amex specifically: every row from one day shares the same parsed date, so
    /// the window would call any two same-day charges at one merchant duplicates.
    private func hasNearbyEqual(_ txn: Txn, in context: ModelContext) -> Bool {
        let card = txn.cardSuffix
        let amount = txn.amountMinor
        let merchant = txn.merchant
        let from = txn.receivedAt.addingTimeInterval(-Self.duplicateWindow)
        let to = txn.receivedAt.addingTimeInterval(Self.duplicateWindow)

        let descriptor = FetchDescriptor<Txn>(
            predicate: #Predicate { other in
                other.cardSuffix == card
                    && other.amountMinor == amount
                    && other.merchant == merchant
                    && other.receivedAt >= from
                    && other.receivedAt <= to
            }
        )
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// SHA-256 of the raw body. Stable across runs and platforms. Retained for
    /// cross-referencing — deliberately NOT the dedup key, and deliberately not declared
    /// `@Attribute(.unique)`, whose uniqueness would be enforced by clobbering, not by lookup.
    static func contentHash(_ body: String) -> String {
        SHA256.hash(data: Data(body.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
