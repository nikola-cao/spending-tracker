//
//  spending_trackerApp.swift
//  spending-tracker
//

import SwiftData
import SwiftUI

@main
struct spending_trackerApp: App {

    private let container: ModelContainer
    private let ledger: LedgerStore

    init() {
        let container = Self.makeContainer()
        self.container = container
        self.ledger = LedgerStore(container: container)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(ledger: ledger)
        }
        .modelContainer(container)
    }

    // MARK: - Store lifecycle

    /// Bump whenever the `@Model` shape changes in a way SwiftData cannot migrate in place —
    /// renaming or removing a property, for instance. Adding a property with a default is
    /// lightweight and does NOT need a bump.
    ///
    /// Why this exists at all: SwiftData treats a property *rename* as dropping the old column
    /// and adding a new one, so every existing row silently gets the new property's default.
    /// That is how `cardLast4` → `cardSuffix` left the Fidelity rows showing an empty card
    /// while the Amex rows, drained afterwards, looked fine. Nothing errored and nothing
    /// warned; the ledger simply displayed `··` for half its rows.
    /// 2 — added `Txn.receivedAt`, so the feed can sort by arrival.
    /// 3 — the ledger now records only charges, so a rebuild clears the non-charge events
    ///     an earlier version had already stored.
    static let ledgerSchemaVersion = 3

    private static let schemaVersionKey = "ledgerSchemaVersion"

    /// Deletes the store and rebuilds it from the journal when the schema has moved on.
    ///
    /// Safe because the store is **derived**: the append-only journal is the source of truth
    /// and the drain replays it in full on the next foreground, so nothing is lost. That
    /// property is the whole reason this is a two-line recovery rather than a migration plan.
    private static func resetStoreIfSchemaChanged(at url: URL) {
        let stored = UserDefaults.standard.integer(forKey: schemaVersionKey)
        guard stored != ledgerSchemaVersion else { return }

        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.set(ledgerSchemaVersion, forKey: schemaVersionKey)
    }

    /// Builds the store, and **never crashes if it cannot**.
    ///
    /// The template this project started from wrapped container creation in
    /// `catch { fatalError(...) }`, which turns any store problem into an app that cannot be
    /// opened at all. That is bad in general and worst here, because the moment a background
    /// launch happens is exactly when a transaction is arriving — an unlaunchable app is an
    /// app that silently stops capturing.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([AlertEvent.self, Txn.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        resetStoreIfSchemaChanged(at: configuration.url)

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            #if DEBUG
            // During development a schema change is the likely cause, and the journal is the
            // real source of truth, so the store can be rebuilt from it. Reset and retry.
            for path in [configuration.url.path,
                         configuration.url.path + "-wal",
                         configuration.url.path + "-shm"] {
                try? FileManager.default.removeItem(atPath: path)
            }
            if let recovered = try? ModelContainer(for: schema, configurations: [configuration]) {
                return recovered
            }
            #endif

            // Release, or a failure that resetting did not fix: launch with an in-memory store
            // so the app still opens and the user can see that something is wrong, rather than
            // being unable to open it at all. Capture is unaffected — the journal is a file.
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even an in-memory container cannot be built, the schema itself is invalid and
            // there is nothing left to degrade to.
            return try! ModelContainer(for: schema, configurations: [inMemory])
        }
    }
}
