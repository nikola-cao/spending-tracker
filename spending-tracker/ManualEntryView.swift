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

    /// The row being changed, or nil when adding one. The form is the same either way — the
    /// fields are the fields — and only what Save does with them differs.
    var editing: Txn?

    var onRecorded: () -> Void

    init(ledger: LedgerStore, editing: Txn? = nil, onRecorded: @escaping () -> Void) {
        self.ledger = ledger
        self.editing = editing
        self.onRecorded = onRecorded

        _kind = State(initialValue: Self.kind(of: editing))
        _merchant = State(initialValue: editing?.merchant ?? "")
        // The canonical decimal, so the field shows what is actually stored rather than
        // whatever happened to be typed when it was first entered. A payment is shown as the
        // amount paid rather than as its effect, so the field reads the same whether the
        // payment is being added or edited.
        _amount = State(initialValue: editing.map {
            Money.decimalString(fromMinor: $0.isPayment ? -$0.amountMinor : $0.amountMinor)
        } ?? "")

        // Off when the row has no date of its own. A Fidelity row's `occurredAt` is its
        // arrival, and showing that in the picker would present a time the message never
        // stated as though it were the purchase date.
        _hasDate = State(initialValue: editing?.occurredAtIsFromMessage ?? true)
        _date = State(initialValue: editing?.occurredAt ?? Date())
        _cardSuffix = State(initialValue: editing?.cardSuffix ?? "")
    }

    /// Which tab a row belongs on.
    ///
    /// Read from the row rather than passed in, so the two can never disagree — and read in
    /// this order, because a payment is neither of the other two and treating it as a deposit
    /// would put its amount on the wrong side of the bank.
    private static func kind(of txn: Txn?) -> Kind {
        guard let txn else { return .charge }
        if txn.isPayment { return .payment }
        return txn.isDeposit ? .deposit : .charge
    }

    @Environment(\.dismiss) private var dismiss

    /// What this form is entering right now.
    ///
    /// A segmented control rather than a second sheet: the fields below are the same either
    /// way, so the switch has to read as changing what the form *means*, not opening a
    /// different form.
    private enum Kind: String, CaseIterable, Identifiable {
        case charge
        case deposit
        /// Paying a card off. Entered as the amount paid and stored negated, because its
        /// effect — on the spend and on the bank — is to take that much away.
        case payment

        var id: String { rawValue }

        var title: String {
            switch self {
            case .charge: return "Charge"
            case .deposit: return "Deposit"
            case .payment: return "Payment"
            }
        }

        /// What this line is called in the journal and the ledger.
        var entryKind: ParsedAlert.Kind {
            switch self {
            case .charge: return .charge
            case .deposit: return .deposit
            case .payment: return .payment
            }
        }

        /// Whether the amount is stored as typed. A payment is not: the number a person enters
        /// is what they paid, and what the ledger needs is what it took away.
        var storesNegated: Bool { self == .payment }
    }

    // Seeded by the initialiser, which is why none of them carries a default here.
    @State private var kind: Kind
    @State private var merchant: String
    @State private var amount: String
    /// The date is optional, but the way it is *chosen* is unchanged — the toggle only decides
    /// whether the picker applies. Leaving it off gives the charge no time of its own, so the
    /// ledger falls back to when the entry was made.
    @State private var hasDate: Bool
    @State private var date: Date
    @State private var cardSuffix: String
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
            .navigationTitle(title)
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

    private var title: String {
        guard editing != nil else { return "Add manually" }
        return "Edit \(kind.title.lowercased())"
    }

    @ViewBuilder
    private var kindSection: some View {
        // No picker when editing. Moving a charge to the deposit tab would change what the row
        // *is* — one touches the bank and the other does not — and "I mistyped the amount" is
        // not a reason to reclassify it. The section header still says which one it is.
        if editing == nil {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(Kind.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                // Switching clears what was typed. The fields look alike but mean different
                // things — a merchant on one side is a source of funds on the other — and
                // carrying a half-filled entry across the switch is how it gets saved as the
                // wrong kind of thing.
                .onChange(of: kind) { _, _ in
                    merchant = ""
                    amount = ""
                    cardSuffix = ""
                    outcome = nil
                }
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
        case .deposit, .payment: return "Set a date"
        }
    }

    private var detailsFooter: String {
        switch kind {
        case .charge:
            return "Only the merchant and the amount are required. Type a minus for a refund."
        case .deposit:
            return "Shows up in the transactions and moves the bank balance. Type a minus to "
                + "subtract it from the bank instead."
        case .payment:
            return "Paying a card off. Comes off both the balance and the bank."
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

        // Editing changes an existing row and never adds one, so it branches off before the
        // two save paths rather than duplicating their field handling.
        if let editing {
            saveEdit(editing, minor)
            return
        }

        switch kind {
        case .charge: saveCharge(minor)
        case .deposit, .payment: saveNonCharge(minor)
        }

        // Only cleared when adding. An edit is about the row behind it, and blanking the form
        // would take away the values it was just saved with.
        merchant = ""
        amount = ""
        cardSuffix = ""
        knownCards = ledger.knownCardSuffixes()
    }

    /// Appends a line that supersedes the row's original one. See `LedgerStore.edit`.
    private func saveEdit(_ txn: Txn, _ minor: Int) {
        // Only a charge has a card, so the other kinds are never sent one — the parser refuses
        // a line that names a card on either of them.
        let card = txn.isDeposit || txn.isPayment ? "" : trimmedCard

        if !txn.isDeposit, !txn.isPayment,
           !card.isEmpty,
           !ManualEntryParser.isValidCardSuffix(card) {
            outcome = .failed("Card must be \(ManualEntryParser.minimumCardDigits) to "
                              + "\(ManualEntryParser.maximumCardDigits) digits, numbers only, "
                              + "or left blank")
            return
        }

        do {
            // A payment is stored as its effect, so the field's figure is negated on the way
            // back in — the same rule the add path uses, and the reason the form reopens on the
            // amount paid rather than on the negative the row holds.
            let stored = txn.isPayment ? -minor : minor

            try ledger.edit(
                txn,
                merchant: trimmedMerchant,
                amount: Money.decimalString(fromMinor: stored),
                date: hasDate ? date : nil,
                cardSuffix: card
            )
        } catch {
            outcome = .failed(error.localizedDescription)
            return
        }

        ledger.drain()
        onRecorded()
        outcome = .recorded(summary: "Updated \(trimmedMerchant)")
    }

    private var amountHint: String {
        switch kind {
        case .charge: return "Enter an amount like 12.34, or -12.34 for a refund"
        case .deposit: return "Enter an amount like 500, or -40 for money going out"
        case .payment: return "Enter the amount you paid, like 825.77"
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

    /// A deposit or a payment is journalled exactly like a charge, and everything else follows.
    ///
    /// Nothing here adjusts the balance or the bank. Both are folded from the journal, so
    /// writing the line *is* moving the money, and a line that failed to be written cannot
    /// leave anything changed with nothing to account for it.
    ///
    /// A payment is stored negated: the number typed is what was paid, and what the ledger
    /// needs is what it took away. Entering a minus reverses that, which is a payment coming
    /// back — a rare thing, but the same rule covers it without a special case.
    private func saveNonCharge(_ minor: Int) {
        let stored = kind.storesNegated ? -minor : minor
        guard journal(kind: kind.entryKind, minor: stored, cardSuffix: "") else { return }

        ledger.drain()
        onRecorded()

        if kind == .payment {
            // The bank, not the balance. Both came down, but the balance is the month's figure
            // and is not the parser's to state; the bank is the one folded from the journal.
            outcome = .recorded(
                summary: "Paid \(formatted(magnitude(of: minor)))"
                    + " — bank now \(formatted(ledger.bankBalanceMinor))")
        } else {
            outcome = .recorded(summary: "\(verb(for: minor)) \(formatted(magnitude(of: minor)))"
                                + " — bank now \(formatted(ledger.bankBalanceMinor))")
        }
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
