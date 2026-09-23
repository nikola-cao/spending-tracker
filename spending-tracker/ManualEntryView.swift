//
//  ManualEntryView.swift
//  spending-tracker
//
//  Record an alert the automation missed.
//

import Foundation
import SwiftUI

/// Type or paste an alert body and record it.
///
/// Two jobs. It is the fallback when the automation is down, and it is the only way to
/// exercise the whole pipeline — journal, drain, parser, ledger — without waiting for a real
/// purchase. Since no live alert has yet flowed end to end, that second job is most of its
/// value right now.
struct ManualEntryView: View {

    let ledger: LedgerStore
    var onRecorded: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case recorded(summary: String)
        case recordedUnreadable
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .font(.footnote.monospaced())
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Message")
                } footer: {
                    Text("Paste the alert exactly as it arrived. It is recorded in the raw "
                         + "journal, so it goes through the same path as a captured alert and "
                         + "can be replayed later.")
                }

                outcomeSection

                Section {
                    Button("Record") { record() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle("Add manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var outcomeSection: some View {
        switch outcome {
        case .none:
            EmptyView()

        case .recorded(let summary):
            Section {
                Label(summary, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Color.green)
                    .font(.subheadline)
            }

        case .recordedUnreadable:
            Section {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Not read as a charge")
                            .font(.subheadline.weight(.medium))
                        Text("Nothing was added to the ledger, and this text will be "
                             + "discarded on the next refresh. Only charges are kept.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(Color.orange)
                }
            }

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                    .font(.subheadline)
            }
        }
    }

    private func record() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }

        do {
            try ledger.appendManualEntry(body)
        } catch {
            outcome = .failed(error.localizedDescription)
            return
        }

        ledger.drain()
        onRecorded()

        // Report what the LEDGER concluded, by asking the same parser the drain uses.
        if let alert = FidelityAlertParser.parseFirst(body), alert.isCharge {
            let amount = (Decimal(alert.amountMinor) / 100)
                .formatted(.currency(code: alert.currencyCode))
            outcome = .recorded(summary: "Recorded \(amount) at \(alert.merchant)")
            text = ""
        } else {
            outcome = .recordedUnreadable
            text = ""
        }
    }
}
