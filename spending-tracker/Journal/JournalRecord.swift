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

    /// "enter" | "result". A plain String rather than an enum so the JSON stays readable
    /// by eye, without a reference table, when that is the only way to see it.
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
