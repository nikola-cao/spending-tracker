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

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            #if DEBUG
            // During development a schema change is the likely cause, and the journal is the
            // real source of truth, so the store can be rebuilt from it. Reset and retry.
            try? FileManager.default.removeItem(at: configuration.url)
            if let recovered = try? ModelContainer(for: schema, configurations: [configuration]) {
                return recovered
            }
            #endif

            // Release, or a failure that resetting did not fix: launch with an in-memory store
            // so the app still opens and the user can see that something is wrong, rather than
            // being unable to open it at all. Capture is unaffected — the journal is a file.
            let inMemory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            // If even an in-memory container cannot be built, the schema itself is invalid and
            // there is nothing to degrade to.
            return try! ModelContainer(for: schema, configurations: [inMemory])
        }
    }
}
