//
//  DiagnosticsView.swift
//  spending-tracker
//
//  Is capture still working, and is the ledger keeping up.
//

import Foundation
import SwiftUI

/// The health surface.
///
/// Everything here answers one of three questions no other screen can: *is the automation still
/// capturing*, *is anything arriving that the parser cannot read*, and — the one this screen did
/// not used to be able to answer — *has this app's process run at all*. All three failures are
/// otherwise silent: the Shortcut keeps firing, the alert is simply absent, or a line is in the
/// journal that nothing can decode.
struct DiagnosticsView: View {

    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var diag = LedgerStore.Diagnostics()
    @State private var journal = ""
    @State private var launches: [Date] = []

    /// How long without a capture before this screen says so out loud.
    ///
    /// A week, for the same reason the journal keeps a non-charge body for a week, and because
    /// it is long enough that an ordinary quiet week raises nothing. The wording is a question
    /// rather than a verdict: the app genuinely cannot tell "nothing was charged" from "capture
    /// stopped", and telling them apart is the whole reason the hint is here.
    private static let captureSilenceWindow: TimeInterval = 7 * 24 * 60 * 60

    /// How long without a launch before this screen raises that in its own right.
    ///
    /// Six days, not seven: on a free Apple ID the profile expires a week after it is signed, and
    /// a warning that arrives after the app can no longer be opened is worth nothing.
    private static let launchSilenceWindow: TimeInterval = 6 * 24 * 60 * 60

    /// How many launches to list. The ring keeps more; this is what a person will read.
    private static let launchesShown = 5

    var body: some View {
        NavigationStack {
            List {
                captureSection
                launchesSection
                ledgerSection
                journalSection
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: journal) {
                        Label("Share journal", systemImage: "square.and.arrow.up")
                    }
                    .disabled(journal.isEmpty)
                }
            }
            .task { reload() }
        }
    }

    private func reload() {
        diag = ledger.diagnostics()
        journal = JournalStore.read(from: JournalLocation.fileURL).exportText
        launches = LaunchLog.recentNewestFirst
    }

    private var captureSection: some View {
        Section {
            row("Last captured", diag.lastCapture.map(relative) ?? "never")
            row("Last manual entry", diag.lastManualEntry.map(relative) ?? "never")

            // A quiet week and a stopped capture look identical from inside the app, so the
            // honest thing is to say both readings out loud and let the user pick. This is the
            // one warning on the screen that is a question rather than a fault.
            if let silent = silence(ending: Date(), since: diag.lastCapture) {
                notice([
                    "Nothing has been captured for \(silent).",
                    "Either nothing has been charged to these cards, or capture has stopped.",
                    "Check that the Shortcuts automations are still enabled, and that this app "
                        + "has been opened since it was last installed.",
                ].joined(separator: " "), severe: false)
            }
        } header: {
            Text("Capture")
        } footer: {
            Text("Manual entries and empty invocations are excluded from \"last captured\" on "
                 + "purpose — otherwise adding one by hand, or a Shortcut handing over nothing, "
                 + "would keep it looking fresh while the ledger quietly stopped growing.")
        }
    }

    /// When the app's own process last ran.
    ///
    /// The capture shortcut ends at an App Intent that is pinned to the app's own process, so
    /// **the app running is a precondition for anything being captured at all** — and no other
    /// screen can show whether that happened. `Last captured` cannot: no charges is an ordinary
    /// state. This can: a launch is stamped whenever the process starts, including a background
    /// launch servicing the intent, so an alert that went missing in a window with no launch
    /// beside it means the intent never got the chance to run.
    private var launchesSection: some View {
        Section {
            ForEach(Array(launches.prefix(Self.launchesShown).enumerated()), id: \.offset) { _, date in
                HStack {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.monospacedDigit())
                    Spacer()
                    Text(relative(date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let previous = LaunchLog.previous,
               Date().timeIntervalSince(previous) >= Self.launchSilenceWindow {
                notice([
                    "This app had not run for \(duration(since: previous)) before now.",
                    "On a free Apple ID the app stops being launchable a week after it is "
                        + "signed, and while it cannot be launched the capture shortcut fires "
                        + "and does nothing.",
                ].joined(separator: " "), severe: true)
            }
        } header: {
            Text("App launches")
        } footer: {
            Text("Newest first, and recorded by the app itself — nothing outside it can see this. "
                 + "A background launch to service an alert is listed alongside one you made by "
                 + "hand, so a missing alert with no launch beside it means the intent was never "
                 + "given the chance to run.")
        }
    }

    private var ledgerSection: some View {
        Section {
            row("Alerts received", "\(diag.eventCount)")
            row("Charges recorded", "\(diag.transactionCount)")
            row("Parser version", "\(diag.parserVersion)")
            row("Held, not a movement", "\(diag.heldLines)")
            row("Empty invocations", "\(diag.emptyInvocations)")
        } header: {
            Text("Ledger")
        } footer: {
            // Built as an array and joined rather than as one chained expression: the README
            // records that a long concatenation of these blows the type checker's time budget,
            // and this is exactly that shape of string.
            Text([
                "Held bodies are ones that resolved to no movement of money — a merchant's own "
                    + "receipt, an OTP, a statement notice.",
                "They are re-read on every pass for a week, so one that starts being recognised "
                    + "becomes a transaction with no special handling.",
                "An empty invocation is different: the automation ran and handed over nothing, "
                    + "which is the tell for a broken Message wiring.",
            ].joined(separator: " "))
        }
    }

    private var journalSection: some View {
        Section {
            row("Lines", "\(diag.journalLines)")
            row("Size", ByteCountFormatter.string(fromByteCount: Int64(diag.journalBytes),
                                                  countStyle: .file))

            if diag.damagedLines > 0 {
                row("Damaged", "\(diag.damagedLines) · \(diag.damagedBytes) bytes")
                notice([
                    "Some lines are in the journal and cannot be decoded.",
                    "Nothing was derived from them, and nothing else records what they held — "
                        + "see ⋯ → Raw journal, where each one can be read and removed.",
                ].joined(separator: " "), severe: true)
            }

            if diag.foreignLines > 0 {
                row("Written elsewhere", "\(diag.foreignLines)")
                notice([
                    "Some lines were written by another process, or into another container.",
                    "Every alert is supposed to be written here, by this app — open ⋯ → Raw "
                        + "journal to see which ones.",
                ].joined(separator: " "), severe: true)
            }

            Text(JournalLocation.directoryPath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
        } header: {
            Text("Raw journal")
        } footer: {
            Text("The journal is the source of truth. The ledger above is derived from it and "
                 + "can be rebuilt by replaying it.")
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    /// A state worth reading rather than skimming, in one shape everywhere it appears.
    ///
    /// `severe` separates "something is wrong" from "this is what the app can and cannot tell
    /// you" — the quiet-week case is the second, and colouring it like a fault would train the
    /// red to be ignored.
    private func notice(_ text: String, severe: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: severe
                  ? "exclamationmark.octagon.fill"
                  : "questionmark.circle.fill")
                .foregroundStyle(severe ? Color.red : Color.orange)
            Text(text)
                .font(.caption)
        }
        .listRowBackground((severe ? Color.red : Color.orange).opacity(0.10))
    }

    /// The window an alert has to be missing for before this screen says so.
    ///
    /// Nil for a date the screen has nothing to say about — never captured on a fresh install is
    /// reported by the row above already, and repeating it as a warning would make a new install
    /// look like a fault.
    private func silence(ending now: Date, since date: Date?) -> String? {
        guard let date else { return nil }
        guard now.timeIntervalSince(date) >= Self.captureSilenceWindow else { return nil }
        return duration(since: date, to: now)
    }

    /// A length of time, for a sentence like *"nothing has been captured for three weeks"*.
    ///
    /// Deliberately not the relative date the rows use: "nothing has been captured for three
    /// weeks ago" is not a sentence, and the two readings are not interchangeable.
    private func duration(since date: Date, to now: Date = Date()) -> String {
        Duration.seconds(now.timeIntervalSince(date)).formatted(
            .units(allowed: [.weeks, .days, .hours], width: .wide, maximumUnitCount: 1)
        )
    }

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
