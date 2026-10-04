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

        if !records.isEmpty {
            ingest(records, into: context, result: &result)
        }

        // After the ingest, never before: an edit replaces a row that has to exist first. On a
        // rebuild the original line is replayed into a row and this lands on top of it, in the
        // same pass — which is what makes an edit survive a rebuild with no extra state.
        applyEdits(instructions.edits, into: context)

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
        result.journalLinesDropped = purgeExpired(records, now: Date())
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
    /// Everything the journal says beyond "here is a row", gathered in one pass.
    ///
    /// The balance and the edits are collected together because both need the same walk in the
    /// same order, and the order is the whole point: an edit line means what it means because
    /// of where it sits relative to the line it supersedes.
    private static func instructions(
        from records: [JournalRecord]
    ) -> (bank: Int?, edits: [JournalInstruction.Edit]) {
        let lines = records.compactMap { record -> (runID: UUID, body: String)? in
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (record.runID, body)
        }

        // The edits are gathered first, because one may supersede a deposit that sits *earlier*
        // in the file and the balance below has to move by the amount that was edited to. Folding
        // in a single pass would read the original and quietly ignore the correction.
        var edits: [JournalInstruction.Edit] = []
        for line in lines {
            if case .edit(let edit)? = JournalInstructionParser.parse(line.body) {
                edits.append(edit)
            }
        }
        // Last one wins, matching `applyEdits`, which replays them in order.
        let editedAmounts = Dictionary(
            edits.map { ($0.occurrenceKey, $0.amountMinor) }, uniquingKeysWith: { _, last in last })

        var bank: Int?
        for line in lines {
            switch JournalInstructionParser.parse(line.body) {
            case .setBankBalance(let minor)?:
                bank = minor
            case .edit?:
                continue
            case nil:
                // Not an instruction, so it is an alert. A charge never touches the bank — it
                // is owed on a card, not yet paid for — but a deposit and a payment both do,
                // and both are stored already signed by the direction the money went.
                for (index, alert) in AlertParsers.parseAll(line.body).enumerated()
                where alert.affectsBank {
                    // Keyed exactly as the ingest keys it, so an edit reaches the right line.
                    // An edit naming a charge simply never matches anything here.
                    let key = "\(line.runID.uuidString)#\(index)"
                    bank = (bank ?? 0) + (editedAmounts[key] ?? alert.amountMinor)
                }
            }
        }
        return (bank, edits)
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
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Runs over the records the drain already read, so it costs nothing extra to decide.
    /// `JournalStore.replace` swaps the file in atomically, so an interruption leaves the
    /// original intact. This is the only place in the app that deliberately discards captured
    /// text.
    private func purgeExpired(_ records: [JournalRecord], now: Date) -> Int {
        guard !records.isEmpty else { return 0 }
        let cutoff = now.addingTimeInterval(-Self.nonChargeRetention)

        let kept = records.filter { record in
            let body = record.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return record.receivedAt > cutoff }
            // A charge or a deposit is kept forever, whenever it arrived: the ledger row it
            // produced has to stay derivable from this line for the rest of the app's life.
            if AlertParsers.parseAll(body).contains(where: \.isLedgerEntry) { return true }
            // An instruction too, and for the same reason — the bank balance is rebuilt by
            // folding over these lines, so dropping one would quietly restate the balance.
            if JournalInstructionParser.isInstruction(body) { return true }
            // Anything else — including an empty body — survives only inside the window.
            return record.receivedAt > cutoff
        }

        guard kept.count < records.count else { return 0 }
        do {
            try JournalStore.replace(contentsOf: journalURL, with: kept)
        } catch {
            // Losing a purge is harmless — the same lines are dropped on a later drain.
            return 0
        }
        return records.count - kept.count
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
    /// was made — exactly what it does for a Fidelity alert, which carries no date.
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
    @discardableResult
    func delete(_ txns: [Txn]) -> Int {
        guard !txns.isEmpty else { return 0 }
        let context = container.mainContext

        // The event carries the invocation identity; deleting it cascades to its transaction.
        var events: [AlertEvent] = []
        var runIDs = Set<UUID>()
        var orphans: [Txn] = []

        for txn in txns {
            if let event = txn.event {
                events.append(event)
                runIDs.insert(event.runID)
            } else {
                // Should not happen — every charge is derived from an event — but a row that
                // somehow has none must still be deletable.
                orphans.append(txn)
            }
        }

        removeJournalRecords(runIDs: runIDs)

        for event in events { context.delete(event) }
        for txn in orphans { context.delete(txn) }
        try? context.save()

        return events.count + orphans.count
    }

    /// Drops every journal line written by the given invocations.
    ///
    /// Atomic and staged like the retention purge, and for the same reason: the journal is the
    /// only thing here that must never be left half-written.
    private func removeJournalRecords(runIDs: Set<UUID>) {
        guard !runIDs.isEmpty else { return }
        let records = JournalStore.readAll(from: journalURL)
        let kept = records.filter { !runIDs.contains($0.runID) }
        guard kept.count < records.count else { return }
        try? JournalStore.replace(contentsOf: journalURL, with: kept)
    }

    // MARK: - Diagnostics

    struct Diagnostics: Equatable {
        var eventCount = 0
        var transactionCount = 0
        var parserVersion = 0
        var journalLines = 0
        var journalBytes = 0
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

        let records = JournalStore.readAll(from: journalURL)
        result.journalLines = records.count
        // Manual entries are excluded: this answers "is the AUTOMATION still capturing".
        result.lastCapture = records.last { $0.note != JournalRecord.manualMarker }?.receivedAt
        result.lastManualEntry = records.last { $0.note == JournalRecord.manualMarker }?.receivedAt

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
