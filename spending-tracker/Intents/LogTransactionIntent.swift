//
//  LogTransactionIntent.swift
//  spending-tracker
//
//  Stage 1's only App Intent. Records what it received and where it ran.
//

import AppIntents
import Foundation

/// Appends a raw card alert to the journal.
///
/// Deliberately NOT marked `nonisolated`. On a type with a `@Parameter var` that is a
/// warning today ("'nonisolated' cannot be applied to mutable stored properties") and an
/// error under Swift 6 language mode. Left unannotated, Swift resolves `perform()` against
/// the protocol's `nonisolated` requirement, so the body already runs off the main actor.
///
/// Deliberately NO `@Dependency`. `AppDependency<Value>.wrappedValue` is a non-optional
/// generic with no zero-argument init, so a dependency this intent cannot itself construct
/// is a compile-time trap for no Stage 1 benefit.
///
/// Deliberately no App Intents *extension* target. An extension exists precisely to run
/// without launching the app, which would move this code into a different sandbox and
/// invalidate `JournalLocation` — the exact thing Stage 1 is trying to observe.
struct LogTransactionIntent: AppIntent {

    static let title: LocalizedStringResource = "Log Transaction Alert"

    static var description: IntentDescription? {
        IntentDescription("Appends a raw card alert to the spending-tracker journal.")
    }

    /// `.background` so the device need not be unlocked. The deprecated `openAppWhenRun`
    /// would require an unlock, defeating the entire point.
    static var supportedModes: IntentModes { [.background] }

    /// iOS 27. Pins execution to the app's own process so the intent shares its container.
    /// This is the assumption the whole design rests on and no one has published field data
    /// for it — hence `processName` in the return value, which makes it observable.
    static var allowedExecutionTargets: IntentExecutionTargets { [.main] }

    static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    /// Required: the user adds this action to a Shortcut by hand.
    static var isDiscoverable: Bool { true }

    /// The ONLY parameter. Passing pre-parsed merchant/amount fields is a documented
    /// failure mode where they intermittently arrive empty; one raw string has one failure
    /// mode and it is visible.
    @Parameter(title: "Message")
    var message: String

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let raw = message
        let runID = UUID()
        let url = JournalLocation.fileURL
        let trimmedIsEmpty = raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        // An empty invocation is itself a Shortcuts plumbing bug, and is exactly the
        // evidence worth having. It IS journalled (with a note) rather than silently
        // dropped — otherwise "ran with empty input" is indistinguishable from "never ran",
        // which is the single most important distinction Stage 1 exists to make.
        do {
            try JournalStore.append(
                .diagnostic(runID: runID, phase: "enter", raw: raw,
                            note: trimmedIsEmpty ? "rejected: empty input" : ""),
                to: url
            )
            if !trimmedIsEmpty {
                // "enter" is written by the shortest possible path; "result" only after the
                // whole path (resolve → create → encode → append → flush) has run twice.
                // A lone "enter" therefore localises a failure that a single record cannot.
                try JournalStore.append(
                    .diagnostic(runID: runID, phase: "result", raw: raw, note: "ok"),
                    to: url
                )
            }
        } catch {
            // Not swallowed: a throw surfaces in the Shortcuts run, which is readable on
            // the device without Xcode.
            return .result(
                value: "ST1 FAIL|\(RuntimeFacts.processName())|\(error)",
                dialog: "Journal write failed: \(error.localizedDescription)"
            )
        }

        if trimmedIsEmpty {
            return .result(value: "REJECTED|empty input", dialog: "Rejected: empty input")
        }

        // Rendered by a "Show Notification" action on the lock screen. This does NOT depend
        // on the app's sandbox, which is what makes the out-of-process case diagnosable when
        // the journal itself is unreadable. `rx` is the U+00AE bit — the sharpest single
        // test of "did the whole string arrive".
        //
        // Built as an array and joined rather than as one concatenated expression: the
        // chained form with inline ternaries is a well-known way to blow the type checker's
        // time budget ("unable to type-check this expression in reasonable time").
        let rx = raw.contains("\u{00AE}") ? 1 : 0
        let fid = FidelityAlertHeuristic.mentionsFidelity(raw) ? 1 : 0
        let grp = RuntimeFacts.appGroupAvailable() ? 1 : 0
        let onMain = RuntimeFacts.isMainThread() ? 1 : 0
        let summary = [
            "ST1 ok",
            RuntimeFacts.processName(),
            "main:\(onMain)",
            "chars:\(raw.count)",
            "rx:\(rx)",
            "fid:\(fid)",
            "grp:\(grp)",
        ].joined(separator: "|")

        return .result(value: summary, dialog: "\(summary)")
    }
}
