//
//  JournalRecord.swift
//  spending-tracker
//
//  One line of journal.jsonl.
//

import Foundation

/// A single append-only journal line — the entire Stage 1 data model.
///
/// `nonisolated` + `let`-only is load-bearing, not style. This target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_APPROACHABLE_CONCURRENCY = YES`
/// (which infers *isolated* conformances), so an unannotated struct would get a
/// main-actor-isolated `Codable` conformance and `JSONEncoder().encode(...)` would be
/// uncallable from the intent. `let`-only matters too: `nonisolated` on a type with a
/// *mutable* stored property is a warning today and an error under Swift 6 language mode.
nonisolated struct JournalRecord: Codable, Sendable, Equatable, Identifiable {
    let id: UUID

    /// Links the `enter` and `result` lines of one invocation.
    let runID: UUID

    /// What kind of journal line this is.
    ///
    /// Historic journals hold an `enter`/`result` pair per alert, written by an earlier
    /// version of the App Intent to localise a failure between two writes. Nothing writes
    /// those any more — one line per alert, always `capture` — but the field stays because
    /// journals are append-only and old lines still have to decode. A plain String rather
    /// than an enum so the JSON stays readable by eye, without a reference table.
    let phase: String

    let receivedAt: Date
    let processName: String
    let bundleIdentifier: String
    let isMainThread: Bool
    let charCount: Int
    let utf8ByteCount: Int
    let hasFidelityPrefix: Bool
    let containsRegisteredTrademark: Bool

    /// Recall-oriented, NOT a transaction test — see `FidelityAlertHeuristic`. Named for
    /// what it actually checks so nobody later mistakes it for a validated parse.
    let mentionsFidelity: Bool

    let appGroupAvailable: Bool
    let journalDirectory: String
    let rawText: String
    let note: String
}

extension JournalRecord {
    /// Marks a line a person typed rather than the automation capturing it.
    ///
    /// Carried in `note` rather than a new field on purpose: `JournalRecord` is `Codable` and
    /// the journal is append-only, so adding a non-optional property would make every existing
    /// line fail to decode — and `readAll` drops undecodable lines, meaning an entire history
    /// would vanish silently.
    ///
    /// The freshness check excludes these. A manual entry must never make capture look alive
    /// when the automation has actually stopped.
    /// `nonisolated` on both, explicitly. The type's `nonisolated` does NOT propagate into an
    /// extension, so without this they are main-actor isolated and unreadable from
    /// `LogTransactionIntent.perform()`, whose body runs off the main actor — a warning today
    /// and an error in the Swift 6 language mode.
    nonisolated static let manualMarker = "manual"

    /// The phase every new line is written with. Earlier versions wrote an `enter`/`result`
    /// pair per alert; see the note on `phase`.
    nonisolated static let capturePhase = "capture"

    /// Explicitly `nonisolated` — the type's isolation does not propagate into an extension.
    nonisolated static func diagnostic(
        runID: UUID,
        phase: String,
        raw: String,
        note: String
    ) -> JournalRecord {
        JournalRecord(
            id: UUID(),
            runID: runID,
            phase: phase,
            receivedAt: Date(),
            processName: RuntimeFacts.processName(),
            bundleIdentifier: RuntimeFacts.bundleIdentifier(),
            isMainThread: RuntimeFacts.isMainThread(),
            charCount: raw.count,
            utf8ByteCount: raw.utf8.count,
            hasFidelityPrefix: raw.hasPrefix("Fidelity"),
            containsRegisteredTrademark: raw.contains("\u{00AE}"),
            mentionsFidelity: FidelityAlertHeuristic.mentionsFidelity(raw),
            appGroupAvailable: RuntimeFacts.appGroupAvailable(),
            journalDirectory: JournalLocation.directoryPath,
            rawText: raw,
            note: note
        )
    }
}
