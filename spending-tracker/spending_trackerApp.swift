//
//  spending_trackerApp.swift
//  spending-tracker
//

import SwiftUI

/// Stage 1 holds no SwiftData store at all — there is no `ModelContainer` here on purpose.
///
/// The template's `ModelContainer` was created inside a `catch { fatalError(...) }`, which
/// turns any store-creation failure into an app that cannot launch. That is a bad property
/// in general and a particularly bad one here, because the moment a background launch
/// happens is exactly when a transaction is arriving. SwiftData arrives in Stage 3, and it
/// will not reintroduce a launch-time `fatalError`.
@main
struct spending_trackerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
