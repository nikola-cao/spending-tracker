//
//  JournalLocation.swift
//  spending-tracker
//
//  Where journal.jsonl lives.
//

import Foundation

/// Resolves the journal directory.
///
/// Written `nonisolated` because this target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
/// which would otherwise make every member here main-actor isolated and uncallable from
/// `LogTransactionIntent.perform()`, whose body runs off the main actor.
nonisolated enum JournalLocation {

    /// Declared (and preferred) but NOT required. `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// returns nil rather than throwing when the entitlement is absent, which is what lets the
    /// same binary work on a free Apple ID and pick up a shared container later with no code change.
    static let appGroupID = "group.com.nikola.spending-tracker"

    /// nil when the App Group entitlement is absent or not yet provisioned.
    static var appGroupContainer: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var directory: URL {
        (appGroupContainer ?? URL.applicationSupportDirectory)
            .appending(path: "Journal", directoryHint: .isDirectory)
    }

    static var fileURL: URL {
        directory.appending(path: "journal.jsonl", directoryHint: .notDirectory)
    }

    /// Recorded on every line. If two lines written in the same run disagree about this,
    /// something wrote from a different container than the app reads from.
    static var directoryPath: String { directory.path(percentEncoded: false) }
}
