//
//  BankBalanceView.swift
//  spending-tracker
//
//  Set the bank balance by hand.
//

import Foundation
import SwiftUI

/// A one-field sheet for the only number in the app the user maintains themselves.
///
/// It writes a journal line rather than setting a property, so the balance is restored by a
/// rebuild exactly like everything else — see `LedgerStore.setBankBalance`.
struct BankBalanceView: View {

    let ledger: LedgerStore
    /// Called after a successful write so the caller can pick the new value up.
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(ledger: LedgerStore, onSaved: @escaping () -> Void) {
        self.ledger = ledger
        self.onSaved = onSaved
        // Seeded from the current value so the sheet opens on what is actually there, rather
        // than blank — the common case is nudging a number, not replacing it.
        _text = State(initialValue: Money.decimalString(fromMinor: ledger.bankBalanceMinor))
    }

    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Amount", text: $text)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .font(.title3.monospacedDigit())
                } header: {
                    Text("Bank balance")
                } footer: {
                    Text(footer)
                }

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                            .font(.subheadline)
                    }
                }
            }
            .navigationTitle("Bank balance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }
                        .disabled(parsed == nil)
                }
            }
        }
    }

    /// Rejects anything `Money` rejects, so a balance this sheet accepts is always one the
    /// display can render — the same rule the manual-entry form holds itself to.
    private var parsed: Int? { Money.signedMinorUnits(from: text) }

    private var footer: String {
        "What is in the bank right now. Saved to the raw journal, so a rebuild keeps it. "
            + "A leading minus is allowed for an overdrawn account."
    }

    private func save() {
        // Re-checked rather than trusted from the disabled state, so the body is correct on
        // its own terms.
        guard let value = parsed else { return }

        do {
            try ledger.setBankBalance(value)
        } catch {
            // The sheet stays open on a failure rather than dismissing over a write that did
            // not happen, which would read as a balance that saved and then silently reverted.
            failure = error.localizedDescription
            return
        }

        onSaved()
        dismiss()
    }
}
