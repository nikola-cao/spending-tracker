//
//  ContentView.swift
//  spending-tracker
//
//  Stage 1's only screen: the journal, plus the diagnostic.
//

import Foundation
import SwiftUI

struct ContentView: View {
    @State private var records: [JournalRecord] = []

    var body: some View {
        NavigationStack {
            List {
                if records.isEmpty {
                    emptyState
                } else {
                    freshnessSection
                    Section {
                        // reversed(), never sorted by date: `.iso8601` JSON dates have
                        // one-second resolution in this SDK, so the timestamp cannot order
                        // two records written in the same run. File position can.
                        ForEach(Array(records.reversed())) { record in
                            JournalRow(record: record)
                        }
                    } header: {
                        Text("\(records.count) lines · newest first")
                    } footer: {
                        Text(JournalLocation.directoryPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Journal")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Gets the journal off the phone without Xcode — mail it, AirDrop it.
                    ShareLink(item: journalText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(records.isEmpty)
                }
            }
            .task { reload() }
            .refreshable { reload() }
        }
    }

    // MARK: - Freshness
    //
    // The app's signing expires every 7 days on a free Apple ID. When it does, the Shortcut
    // still fires and the App Intent simply never runs — capture stops with no error
    // anywhere. This banner is the only thing that makes that visible, which is why it is
    // the first thing on the screen rather than a debug affordance.

    private var lastWrite: Date? { records.last?.receivedAt }

    private var staleness: (text: String, isStale: Bool) {
        guard let lastWrite else { return ("Never captured", true) }
        let hours = Date().timeIntervalSince(lastWrite) / 3600
        let ago = lastWrite.formatted(.relative(presentation: .named))
        return ("Last capture: \(ago)", hours > 48)
    }

    private var freshnessSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: staleness.isStale
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(staleness.isStale ? .red : .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(staleness.text).font(.subheadline.weight(.medium))
                    if staleness.isStale {
                        Text("Nothing has been captured in over 48 hours. Re-sign the app "
                             + "from Xcode (⌘R), then check the automation is still enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listRowBackground(staleness.isStale ? Color.red.opacity(0.10) : nil)
    }

    // MARK: - Empty state
    //
    // The empty state IS a diagnostic: "nothing ever ran" is the failure this screen will
    // most often be showing, and the four causes below are the ones that actually happen.

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Journal is empty", systemImage: "tray")
        } description: {
            VStack(alignment: .leading, spacing: 10) {
                Text("Nothing has written to this file yet.")
                Text("""
                    1. Is the automation enabled, with "Run Immediately" on?
                    2. Is Shortcuts → Privacy → "Allow Running When Locked" on?
                    3. Does the sub-shortcut run on its own, from the Shortcuts app?
                    4. Did you force-quit this app? (iOS won't relaunch it — don't)
                    """)
                Text(JournalLocation.directoryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var journalText: String {
        records
            .map { "\($0.phase)\t\($0.processName)\t\($0.charCount)\t\($0.rawText)" }
            .joined(separator: "\n")
    }

    private func reload() {
        records = JournalStore.readAll(from: JournalLocation.fileURL)
    }
}

private struct JournalRow: View {
    let record: JournalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(record.phase == "enter" ? "▸ enter" : "✓ result")
                    .font(.caption.bold())
                    .foregroundStyle(record.phase == "enter" ? .orange : .green)
                Text(record.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(record.charCount) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // The four bits worth seeing at a glance, without tapping anything.
            // Hoisted into `diagnosticLine` for the same reason as in the intent: a
            // concatenation of interpolated ternaries blows the type checker's budget.
            Text(diagnosticLine)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(record.rawText)
                .font(.footnote.monospaced())

            // Only surface a note when it carries information. "ok" is the success case and
            // is already implied by the phase. (The ternary form also failed to type-check:
            // `.secondary` is a HierarchicalShapeStyle and `.red` is a Color.)
            if !record.note.isEmpty && record.note != "ok" {
                Text(record.note)
                    .font(.caption2)
                    .foregroundStyle(Color.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var diagnosticLine: String {
        let main = record.isMainThread ? "y" : "n"
        let rx = record.containsRegisteredTrademark ? "y" : "n"
        let fid = record.mentionsFidelity ? "y" : "n"
        let grp = record.appGroupAvailable ? "y" : "n"
        return [
            record.processName,
            "main:\(main)",
            "®:\(rx)",
            "fid:\(fid)",
            "grp:\(grp)",
        ].joined(separator: " · ")
    }
}

#Preview {
    ContentView()
}
