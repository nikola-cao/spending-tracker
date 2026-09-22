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
/// Everything here answers one of two questions that no other screen can: *is the automation
/// still capturing*, and *is anything arriving that the parser cannot read*. Both failures are
/// otherwise silent — the Shortcut keeps firing, or the alert is simply absent.
struct DiagnosticsView: View {

    let ledger: LedgerStore
    @Environment(\.dismiss) private var dismiss
    @State private var diag = LedgerStore.Diagnostics()
    @State private var journal = ""

    var body: some View {
        NavigationStack {
            List {
                captureSection
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
        journal = JournalStore.readAll(from: JournalLocation.fileURL)
            .map { "\($0.receivedAt.formatted(.iso8601))\t\($0.note)\t\($0.rawText)" }
            .joined(separator: "\n")
    }

    private var captureSection: some View {
        Section {
            row("Last captured", diag.lastCapture.map(relative) ?? "never")
            row("Last manual entry", diag.lastManualEntry.map(relative) ?? "never")
        } header: {
            Text("Capture")
        } footer: {
            Text("Manual entries are excluded from \"last captured\" on purpose — otherwise "
                 + "adding one by hand would hide the automation having stopped.")
        }
    }

    private var ledgerSection: some View {
        Section("Ledger") {
            row("Alerts received", "\(diag.eventCount)")
            row("Charges recorded", "\(diag.transactionCount)")
            row("Not read as a charge", "\(diag.needsReviewCount)")
            row("Parser version", "\(diag.parserVersion)")
        }
    }

    private var journalSection: some View {
        Section {
            row("Lines", "\(diag.journalLines)")
            row("Size", ByteCountFormatter.string(fromByteCount: Int64(diag.journalBytes), countStyle: .file))
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

    private func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
