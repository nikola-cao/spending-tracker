//
//  ManualEntryView.swift
//  spending-tracker
//
//  Record a charge the automation missed.
//

import Foundation
import SwiftUI

/// A form for entering a charge by hand.
///
/// The fields are composed into the canonical line `ManualEntryParser` reads, and journalled —
/// so a hand-entered charge takes the same path as a captured one and behaves identically
/// everywhere: it is drained the same way, covered by the same retention window, and removed
/// from the raw journal when deleted from the feed.
struct ManualEntryView: View {

    let ledger: LedgerStore
    var onRecorded: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var merchant = ""
    @State private var amount = ""
    /// The date is optional, but the way it is *chosen* is unchanged — the toggle only decides
    /// whether the picker applies. Leaving it off gives the charge no time of its own, so the
    /// ledger falls back to when the entry was made.
    @State private var hasDate = true
    @State private var date = Date()
    @State private var cardSuffix = ""
    @State private var knownCards: [String] = []
    @State private var outcome: Outcome?

    private enum Outcome: Equatable {
        case recorded(summary: String)
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                chargeSection
                cardSection
                outcomeSection

                Section {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .navigationTitle("Add manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { knownCards = ledger.knownCardSuffixes() }
        }
    }

    // MARK: - Sections

    private var chargeSection: some View {
        Section("Charge") {
            TextField("Merchant", text: $merchant)
                .autocorrectionDisabled()
            TextField("Amount", text: $amount)
                .keyboardType(.decimalPad)
            Toggle("Set a purchase date", isOn: $hasDate)
            if hasDate {
                DatePicker("Purchase date", selection: $date, displayedComponents: .date)
            }
        }
    }

    private var cardSection: some View {
        Section {
            HStack(spacing: 12) {
                TextField("Last 4 or 5 digits", text: $cardSuffix)
                    .keyboardType(.numberPad)
                    .onChange(of: cardSuffix) { _, newValue in
                        // Extra characters simply never appear, rather than being accepted and
                        // then rejected on save. Non-digits go too: the numeric keypad makes
                        // them unlikely, but a paste can still bring them in.
                        let digits = newValue.filter { $0.isASCII && $0.isNumber }
                        let capped = String(digits.prefix(ManualEntryParser.maximumCardDigits))
                        if capped != newValue { cardSuffix = capped }
                    }

                // The same value, two ways in: typing covers a card that has never been seen
                // before, and the menu covers the common case in one tap.
                Menu {
                    ForEach(knownCards, id: \.self) { known in
                        Button(known) { cardSuffix = known }
                    }
                } label: {
                    Label("Previously used", systemImage: "chevron.up.chevron.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(knownCards.isEmpty)
            }
        } header: {
            Text("Card")
        } footer: {
            Text(cardFooter)
        }
    }

    private var cardFooter: String {
        let range = "\(ManualEntryParser.minimumCardDigits) to "
            + "\(ManualEntryParser.maximumCardDigits) digits"
        var text = "Optional. Digits only, \(range)."
        if !knownCards.isEmpty {
            text += " Previously used: " + knownCards.joined(separator: ", ") + "."
        }
        return text
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

        case .failed(let message):
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.red)
                    .font(.subheadline)
            }
        }
    }

    // MARK: - Validation

    private var trimmedMerchant: String {
        merchant.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCard: String {
        cardSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Accepts a leading `$` because it is a natural thing to type, then defers to the same
    /// strict converter every other source uses — so an amount this form accepts cannot be one
    /// the parser later refuses.
    private var amountMinor: Int? {
        var text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("$") { text.removeFirst() }
        return Money.minorUnits(from: text)
    }

    /// Only the merchant and the amount are required. A card that *is* filled in still has to
    /// be well-formed — "123" is a mistake, not an omission.
    private var canSave: Bool {
        guard !trimmedMerchant.isEmpty, amountMinor != nil else { return false }
        return trimmedCard.isEmpty || ManualEntryParser.isValidCardSuffix(trimmedCard)
    }

    // MARK: - Saving

    private func save() {
        // Re-checked here rather than trusted from `canSave`, so the body of this method is
        // correct on its own terms.
        guard let minor = amountMinor else {
            outcome = .failed("Enter an amount like 12.34")
            return
        }
        guard trimmedCard.isEmpty || ManualEntryParser.isValidCardSuffix(trimmedCard) else {
            outcome = .failed("Card must be \(ManualEntryParser.minimumCardDigits) to "
                              + "\(ManualEntryParser.maximumCardDigits) digits, numbers only, "
                              + "or left blank")
            return
        }
        guard !trimmedMerchant.isEmpty else {
            outcome = .failed("Enter a merchant")
            return
        }

        do {
            try ledger.appendManualCharge(
                merchant: trimmedMerchant,
                // The canonical decimal, not what was typed: the journal line has to be
                // re-readable regardless of how the amount was written.
                amount: Money.decimalString(fromMinor: minor),
                // Nil when the date was switched off — which is not the same as "today".
                date: hasDate ? date : nil,
                cardSuffix: trimmedCard
            )
        } catch {
            outcome = .failed(error.localizedDescription)
            return
        }

        ledger.drain()
        onRecorded()

        outcome = .recorded(
            summary: "Recorded \((Decimal(minor) / 100).formatted(.currency(code: "USD")))"
                + " at \(trimmedMerchant)"
        )

        merchant = ""
        amount = ""
        cardSuffix = ""
        knownCards = ledger.knownCardSuffixes()
    }
}
