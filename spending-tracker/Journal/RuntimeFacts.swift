//
//  RuntimeFacts.swift
//  spending-tracker
//
//  Facts about where the intent ran. Synchronous on purpose.
//

import Foundation

/// Synchronous shims over process-level facts.
///
/// These exist because `Thread.isMainThread` is annotated
/// `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` (NSThread.h:126 — "Work intended for the main actor
/// should be marked with @MainActor") and `perform()` is `async`. Reading it directly from
/// the intent body is a warning today and an error under the Swift 6 language mode; routing
/// it through a synchronous `nonisolated` function is the supported way to ask.
nonisolated enum RuntimeFacts {

    static func isMainThread() -> Bool { Thread.isMainThread }

    /// The load-bearing one. `ProcessInfo.processInfo.processName` is the executable name —
    /// `spending-tracker` when this ran in the app's own process. Anything else means an
    /// out-of-process executor ran the intent, and the journal may have gone somewhere the
    /// app cannot read.
    static func processName() -> String { ProcessInfo.processInfo.processName }

    static func bundleIdentifier() -> String { Bundle.main.bundleIdentifier ?? "<nil>" }

    static func appGroupAvailable() -> Bool { JournalLocation.appGroupContainer != nil }
}
