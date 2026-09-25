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
/// A binding rather than a `LedgerStore` call: this value does not go through the journal, so
/// there is no drain to run and nothing to reconcile. See `BankBalance` for why it is not in
/// the store.
struct BankBalanceView: View {

    @Binding var minorUnits: Int

    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(minorUnits: Binding<Int>) {
        _minorUnits = minorUnits
        // Seeded from the stored value so the sheet opens on what is actually there, rather
        // than blank — the common case is nudging a number, not replacing it.
        _text = State(initialValue: Money.decimalString(fromMinor: minorUnits.wrappedValue))
    }

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
                    Text("What is in the bank right now. A leading minus is allowed for an "
                         + "overdrawn account.")
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

    private func save() {
        // Re-checked rather than trusted from the disabled state, so the body is correct on
        // its own terms.
        guard let value = parsed else { return }
        minorUnits = value
        dismiss()
    }
}

#Preview {
    BankBalanceView(minorUnits: .constant(124_050))
}
