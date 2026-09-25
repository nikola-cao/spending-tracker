//
//  ManualEntryView.swift
//  spending-tracker
//
//  Record a charge the automation missed, or money moving in or out of the bank.
//

import Foundation
import SwiftUI

/// A form for entering something by hand: a card charge, or a deposit.
///
/// One form rather than two because from the user's side these are the same act — typing in a
/// number nothing captured — and they differ only in where the number goes.
///
/// A **charge** is composed into the canonical line `ManualEntryParser` reads and journalled,
/// so it takes the same path as a captured one: drained the same way, covered by the same
/// retention window, and removed from the raw journal when deleted from the feed.
///
/// A **deposit** deliberately does not go through the journal at all. The journal is what the
/// ledger is derived from and the ledger holds only charges, so a deposit line would either
/// become a charge or be purged after a week as a non-charge. It is a change to the bank
/// balance instead, which is stored outside all of that — see `BankBalance`.
struct ManualEntryView: View {

    let ledger: LedgerStore
    var onRecorded: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// What this form is entering right now.
    ///
    /// A segmented control rather than a second sheet: the fields below are the same either
    /// way, so the switch has to read as changing what the form *means*, not opening a
    /// different form.
    private enum Kind: String, CaseIterable, Identifiable {
        case charge
        case deposit

        var id: String { rawValue }

        var title: String {
            switch self {
            case .charge: return "Charge"
            case .deposit: return "Deposit"
            }
        }
    }

    @State private var kind: Kind = .charge
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
                kindSection
                detailsSection
                // Absent rather than shown empty: a deposit has no card, and an empty card
                // field would invite someone to fill it in.
                if kind == .charge { cardSection }
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

    private var kindSection: some View {
        Section {
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            // Switching clears what was typed. The fields look alike but mean different
            // things — a merchant on one side is a source of funds on the other — and carrying
            // a half-filled entry across the switch is how it gets saved as the wrong kind.
            .onChange(of: kind) { _, _ in
                merchant = ""
                amount = ""
                cardSuffix = ""
                outcome = nil
            }
        }
    }

    private var detailsSection: some View {
        Section {
            TextField("Merchant", text: $merchant)
                .autocorrectionDisabled()
            TextField("Amount", text: $amount)
                // Both kinds may be negative now — a refund on a charge, money leaving the
                // bank on a deposit — and the decimal pad has no minus key.
                .keyboardType(.numbersAndPunctuation)
            Toggle(detailsDateLabel, isOn: $hasDate)
            if hasDate {
                DatePicker("Date", selection: $date, displayedComponents: .date)
            }
        } header: {
            Text(kind.title)
        } footer: {
            Text(detailsFooter)
        }
    }

    private var detailsDateLabel: String {
        switch kind {
        case .charge: return "Set a purchase date"
        case .deposit: return "Set a date"
        }
    }

    private var detailsFooter: String {
        switch kind {
        case .charge:
            return "Only the merchant and the amount are required. Type a minus for a refund."
        case .deposit:
            return "Shows up in the transactions and moves the bank balance. Type a minus to "
                + "subtract it from the bank instead."
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

    /// The amount, signed, the same way on both tabs.
    ///
    /// A minus means the same thing in both places — money coming back — so there is no reason
    /// for the tabs to read it differently. The strict parser is still what the *captured*
    /// sources use; only a person typing gets a minus key.
    private var parsedAmount: Int? { Money.signedMinorUnits(from: amount) }

    /// Only the merchant and the amount are required. A card that *is* filled in still has to
    /// be well-formed — "123" is a mistake, not an omission.
    private var canSave: Bool {
        guard !trimmedMerchant.isEmpty, parsedAmount != nil else { return false }
        // Only a charge has a card, so only a charge can have a malformed one.
        guard kind == .charge else { return true }
        return trimmedCard.isEmpty || ManualEntryParser.isValidCardSuffix(trimmedCard)
    }

    // MARK: - Saving

    private func save() {
        // Re-checked here rather than trusted from `canSave`, so the body of this method is
        // correct on its own terms.
        guard !trimmedMerchant.isEmpty else {
            outcome = .failed("Enter a merchant")
            return
        }
        guard let minor = parsedAmount else {
            outcome = .failed(amountHint)
            return
        }

        switch kind {
        case .charge: saveCharge(minor)
        case .deposit: saveDeposit(minor)
        }

        merchant = ""
        amount = ""
        cardSuffix = ""
        knownCards = ledger.knownCardSuffixes()
    }

    private var amountHint: String {
        switch kind {
        case .charge: return "Enter an amount like 12.34, or -12.34 for a refund"
        case .deposit: return "Enter an amount like 500, or -40 for money going out"
        }
    }

    private func saveCharge(_ minor: Int) {
        guard trimmedCard.isEmpty || ManualEntryParser.isValidCardSuffix(trimmedCard) else {
            outcome = .failed("Card must be \(ManualEntryParser.minimumCardDigits) to "
                              + "\(ManualEntryParser.maximumCardDigits) digits, numbers only, "
                              + "or left blank")
            return
        }

        guard journal(kind: .charge, minor: minor, cardSuffix: trimmedCard) else { return }

        ledger.drain()
        onRecorded()
        outcome = .recorded(summary: "Recorded \(formatted(minor)) at \(trimmedMerchant)")
    }

    /// A deposit is journalled exactly like a charge, and the bank follows from that.
    ///
    /// Nothing here adjusts the balance. It is folded from the journal — the last value set,
    /// plus every deposit after it — so writing the line *is* moving the money, and a line that
    /// failed to be written cannot leave the bank changed with nothing to account for it.
    private func saveDeposit(_ minor: Int) {
        guard journal(kind: .deposit, minor: minor, cardSuffix: "") else { return }

        ledger.drain()
        onRecorded()
        outcome = .recorded(summary: "\(verb(for: minor)) \(formatted(magnitude(of: minor)))"
                            + " — bank now \(formatted(ledger.bankBalanceMinor))")
    }

    /// Writes the canonical line, reporting rather than throwing so both callers stay flat.
    private func journal(kind: ParsedAlert.Kind, minor: Int, cardSuffix: String) -> Bool {
        do {
            try ledger.appendManual(
                kind: kind,
                merchant: trimmedMerchant,
                // The canonical decimal, not what was typed: the journal line has to be
                // re-readable regardless of how the amount was written.
                amount: Money.decimalString(fromMinor: minor),
                // Nil when the date was switched off — which is not the same as "today".
                date: hasDate ? date : nil,
                cardSuffix: cardSuffix
            )
        } catch {
            outcome = .failed(error.localizedDescription)
            return false
        }
        return true
    }

    private func verb(for minor: Int) -> String { minor < 0 ? "Subtracted" : "Added" }

    private func magnitude(of minor: Int) -> Int { minor < 0 ? -minor : minor }

    private func formatted(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.currency(code: "USD"))
    }
}
