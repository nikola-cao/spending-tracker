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

    /// Called after a change lands, so the feed and the figures are rebuilt from the journal.
    var onRecorded: () -> Void

    /// Called when the journal line behind the row was deleted from this sheet.
    ///
    /// The argument is nil for a clean deletion, and a message when the journal half landed but
    /// the store refused the save. This exists rather than a bare `dismiss()` because the caller
    /// must clear the item it is presenting **before** it refreshes: the row has been deleted
    /// from the store, and this view's initialiser reads the row's fields every time SwiftUI
    /// re-evaluates the sheet's content closure.
    var onDeleted: (String?) -> Void

    init(
        ledger: LedgerStore,
        editing: Txn? = nil,
        onDeleted: @escaping (String?) -> Void = { _ in },
        onRecorded: @escaping () -> Void
    ) {
        self.ledger = ledger
        self.editing = editing
        self.onDeleted = onDeleted
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

        // The row's *effective* category, which is what the drain already resolved onto it —
        // whether that came from a line about this row, a rule about its merchant, or nothing.
        self.originalCategory = editing?.categoryRaw ?? ""
        _category = State(initialValue: editing?.categoryRaw ?? "")
    }

    /// The category the row had when the form opened.
    ///
    /// Kept so that saving an unrelated change — an amount, a date — does not write a category
    /// line nobody asked for. Without it, editing the amount of a row that follows its merchant's
    /// rule would quietly convert that into a decision about this one transaction, and the row
    /// would stop following the rule from then on. A form that changes less than it is asked to
    /// is the kind of thing nobody notices until it matters.
    private let originalCategory: String

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
        /// effect — on what is owed on the card, and on the bank — is to take that much away.
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
    /// The category token, or `""` for none. `""` is a real choice, not an empty field: it means
    /// this row is filed under nothing and no rule for its merchant may put one back.
    @State private var category: String
    /// Whether the chosen category should also become the rule for this merchant, now and in
    /// future. Off by default: a one-off correction is the common act, and a toggle that was
    /// already on is how a single mistake silently rewrites a merchant's whole history.
    @State private var rememberForMerchant = false
    @State private var knownCards: [String] = []
    @State private var outcome: Outcome?

    /// What the journal holds for the row being edited, or nil until the first read.
    ///
    /// Nil is deliberately not "no line": drawing the section before the read finishes would
    /// flash "no journal line" on every row that has one.
    @State private var journalLink: LedgerStore.JournalLink?

    /// Whether the whole body is shown rather than the preview. See `previewBodyLines`.
    @State private var isShowingFullJournalBody = false

    /// The line a deletion is asking about. The swipe in the Raw journal asks first, and this
    /// is the same destruction through a different door.
    @State private var pendingJournalDeletion: JournalRecord?

    /// A deletion that did not happen, shown beside the line it did not remove. Kept out of
    /// `outcome` because that section sits above the Save button, and this one is about the
    /// section below it.
    @State private var journalDeletionError: String?

    /// Set once the line — and possibly the row with it — has been deleted. The form must not
    /// read `editing` again: the instance may have been removed from the store.
    @State private var journalWasDeleted = false

    private enum Outcome: Equatable {
        case recorded(summary: String)
        case failed(String)
    }

    var body: some View {
        // The row this form was editing has been deleted from the store, and its journal line
        // with it. The caller clears the presentation item in the same action, so this view is
        // on its way out; it must not read the invalidated model in the meantime.
        if journalWasDeleted {
            EmptyView()
        } else {
            NavigationStack {
                Form {
                    kindSection
                    detailsSection
                    // Absent rather than shown empty: a deposit has no card, and an empty card
                    // field would invite someone to fill it in.
                    if kind == .charge { cardSection }
                    categorySection
                    outcomeSection

                    Section {
                        Button("Save") { save() }
                            .disabled(!canSave)
                    }

                    // Below the Save button: the raw evidence the row was recorded from. Only
                    // while editing — a row being added has no line until the drain has run.
                    if editing != nil { rawJournalSection }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
                // One dialog, outside the section: the section is rebuilt when the list is
                // reloaded, and a dialog attached to it would be torn down with it. Same words
                // as the Raw journal screen, because it is the same destruction.
                .confirmationDialog(
                    "Delete this journal line?",
                    isPresented: Binding(
                        get: { pendingJournalDeletion != nil },
                        set: { if !$0 { pendingJournalDeletion = nil } }
                    ),
                    titleVisibility: .visible,
                    presenting: pendingJournalDeletion
                ) { record in
                    Button("Delete line", role: .destructive) {
                        deleteJournalLine(record)
                    }
                    Button("Cancel", role: .cancel) { pendingJournalDeletion = nil }
                } message: { record in
                    Text(record.outcome.message(storedRows: ledger.rowsRecorded(by: record)))
                }
                .task {
                    knownCards = ledger.knownCardSuffixes()
                    reloadJournalLink()
                }
            }
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

    /// Changing a row's category, and optionally every row from its merchant.
    ///
    /// **Only when editing, and only on a charge.** Adding is excluded because a category line
    /// has to name a row that already exists, and the row a manual entry produces does not exist
    /// until the drain has run. A payment or a deposit is excluded because it is not
    /// *uncategorized* — it is not categorizable: filing a card payoff under Dining would make
    /// that figure a lie, so the picker is not offered where the answer would be refused.
    @ViewBuilder
    private var categorySection: some View {
        if let editing, editing.isCategorizable {
            Section {
                Picker("Category", selection: $category) {
                    Text("None").tag("")
                    ForEach(SpendingCategory.all, id: \.self) { token in
                        Text(SpendingCategory.displayName(for: token)).tag(token)
                    }
                }
                // A menu, explicitly. Left to the default this is a navigation link inside a
                // form, which pushes a whole screen for six taps' worth of choice — and the
                // style is inferred from context, so it would change under a future layout.
                .pickerStyle(.menu)
                .accessibilityIdentifier("Category")
                // A category is journalled as an instruction naming the row, so it needs the
                // capture line just as Save does. See `canWriteInstructions`.
                .disabled(!canWriteInstructions)
                // Offered only once there is something to remember. "Remember that this
                // merchant has no category" is a different act from clearing one row, and the
                // journal has no line for it — clearing a rule is deleting it from the Raw
                // journal, which is deliberate because it puts every row back in the queue.
                //
                // Also withheld when there is nothing to key on: a person-to-person payment with
                // no note has a descriptor that is only a person's name, and a rule about a
                // person is not a rule about what was bought.
                if !category.isEmpty, !ruleMerchant.isEmpty {
                    Toggle(rememberLabel, isOn: $rememberForMerchant)
                        // This writes a merchant rule, which is stored in the journal but does
                        // not name a row. It is still offered only when the row itself can be
                        // changed, so a form in an unreadable state is not half alive.
                        .disabled(!canWriteInstructions)
                }
            } header: {
                Text("Category")
            } footer: {
                Text(categoryFooter)
            }
        }
    }

    /// What a merchant rule would be keyed on: the descriptor, or the note of a person-to-person
    /// payment. Empty when there is nothing to key on. See `CategorizationIdentity`.
    private var ruleMerchant: String {
        CategorizationIdentity.merchant(for: trimmedMerchant)
    }

    private var displayMerchant: String {
        ruleMerchant.isEmpty ? "this transaction" : ruleMerchant
    }

    private var rememberLabel: String { "Remember for \(displayMerchant)" }

    private var categoryFooter: String {
        if category.isEmpty {
            return "No category. This row stays out of every category — including any rule "
                + "there is for \(displayMerchant)."
        }
        if rememberForMerchant {
            return "Every transaction filed under \(displayMerchant) gets this, now and in the "
                + "future. Rows you have filed individually keep their own."
        }
        return "Applies to this transaction only. Turn on Remember to file everything under "
            + "\(displayMerchant) the same way."
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

    // MARK: - The raw evidence

    /// The line or lines behind this row, drawn with the component the Raw journal screen uses.
    ///
    /// Shown only while editing, and only once the read has finished: before that, an empty
    /// section would claim there is no line for every row that has one.
    ///
    /// The cases are kept apart because "no line" is not one state — see
    /// `LedgerStore.JournalLink`. A form must know which one it is in, because a save against a
    /// line the journal does not hold writes an instruction no rebuild could ever replay.
    @ViewBuilder
    private var rawJournalSection: some View {
        if let journalLink {
            switch journalLink {
            case .lines(let lines):
                Section {
                    ForEach(lines) { record in
                        JournalRow(
                            record: record,
                            bodyLineLimit: isShowingFullJournalBody ? nil : Self.previewBodyLines
                        )
                    }

                    if showsFullBodyToggle(for: lines) {
                        Button(isShowingFullJournalBody ? "Show less" : "Show full text") {
                            isShowingFullJournalBody.toggle()
                        }
                        .font(.footnote)
                    }

                    if let journalDeletionError {
                        Label(journalDeletionError,
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.red)
                    }

                    Button("Delete journal line", role: .destructive) {
                        pendingJournalDeletion = lines.first
                    }
                    .accessibilityIdentifier("Delete journal line")
                } header: {
                    Text(lines.count == 1
                        ? "Raw journal line"
                        : "\(lines.count) raw journal lines")
                } footer: {
                    // Why the amount above may not match the body: an edit is appended, never
                    // written over the evidence.
                    Text("The line this transaction was recorded from. Saving a change adds a "
                         + "line to the journal rather than rewriting this one.")
                }

            case .noEvent:
                rawEvidenceUnavailableSection(
                    "This transaction has no journal line, so there is nothing to show or "
                        + "delete here. Swipe it in the feed to remove the row."
                )

            case .missing:
                rawEvidenceUnavailableSection(
                    "The raw journal holds no readable line for this transaction. It may have "
                        + "been deleted already. Swipe the transaction in the feed to remove "
                        + "the row."
                )

            case .unreadable:
                rawEvidenceUnavailableSection(
                    "The raw journal is there and could not be read, so the line behind this "
                        + "transaction cannot be shown or changed until the file can be read."
                )
            }
        } else {
            // The read runs in `.task`, and Save is held disabled until it finishes. Saying so
            // is the difference between "this row cannot be edited" and "the app is still
            // reading" — a greyed-out Save with no explanation is neither.
            Section {
                Text("Reading the raw journal…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Raw journal line")
            }
        }
    }

    /// The section for a row with no usable line behind it.
    ///
    /// A change saved here would name an occurrence the journal can no longer produce, so Save
    /// is refused too — see `canWriteInstructions`. The message names the state and, where it
    /// applies, the one action still real: removing the row from the feed.
    private func rawEvidenceUnavailableSection(_ message: String) -> some View {
        Section {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Raw journal line")
        } footer: {
            Text("A change cannot be recorded from here.")
        }
    }

    /// Whether the preview can be hiding something, so the expander is worth offering.
    ///
    /// **Two measures, because either can be the binding one.** The cap is eight rendered lines,
    /// and rendered lines are not newlines: an emailed alert is many short newline-separated
    /// lines, while a text is one long line that wraps. Counting newlines catches the first;
    /// the character bound catches the second. Deriving the answer from only one of them is what
    /// let a real eleven-line alert be clipped with no way to expand it.
    private func showsFullBodyToggle(for lines: [JournalRecord]) -> Bool {
        lines.contains { record in
            record.rawText.count > Self.previewBodyCharacters
                || record.rawText.split(separator: "\n", omittingEmptySubsequences: false).count
                    > Self.previewBodyLines
        }
    }

    /// How much of a body the detail shows before offering the rest.
    ///
    /// The Raw journal screen has no limit: there the line is the screen. Here it is a section
    /// under the form, and an Amex body is a whole email — a destructive control below dozens
    /// of screenfuls of text is unreachable, and the form itself becomes expensive to lay out.
    /// A Fidelity text is a couple of hundred characters and loses nothing to the cap.
    ///
    /// The character bound sits below the eight-line capacity of the widest phone on purpose:
    /// it is the coarse catch for a single long line that wraps, not a claim about how many
    /// characters fit on eight lines.
    private static let previewBodyLines = 8
    private static let previewBodyCharacters = 400

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

    /// Whether a change saved here can still be recorded against the row's journal line.
    ///
    /// A save appends an instruction naming the row's occurrence, and the store is rebuilt by
    /// replaying the journal. Against a line that is gone or unreadable, the change would work
    /// on screen until the next rebuild and then vanish — silently, because there would be no
    /// line left to apply it from. So the form refuses rather than pretending, and the raw
    /// section says which state it is in.
    private var canWriteInstructions: Bool {
        guard editing != nil else { return true }
        guard let journalLink else { return false }
        switch journalLink {
        case .lines: return true
        case .noEvent, .missing, .unreadable: return false
        }
    }

    /// Only the merchant and the amount are required. A card that *is* filled in still has to
    /// be well-formed — "123" is a mistake, not an omission.
    private var canSave: Bool {
        // Nothing can be recorded against a row whose line the journal no longer holds.
        guard canWriteInstructions else { return false }
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
        // Checked here too, not only in `canSave`, so a save that somehow arrives while the raw
        // section is in an unavailable state cannot write an instruction no rebuild could replay.
        guard canWriteInstructions else {
            outcome = .failed("This transaction cannot be changed: the journal line it was "
                              + "recorded from is not there.")
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
        // A deposit never has a card. A payment keeps whatever it already had: the form offers
        // no card field for one, but an Amex payment arrives knowing which card it settled, and
        // writing "" here would quietly erase that the first time the row was edited.
        let card = txn.isDeposit ? "" : (txn.isPayment ? txn.cardSuffix : trimmedCard)

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

            // Written only when it actually changed, so saving an amount leaves a row following
            // its merchant's rule rather than freezing it to today's answer. An empty label is
            // written as an explicit clear rather than skipped — see `LedgerStore.setCategory`.
            if category != originalCategory {
                try ledger.setCategory(txn, label: category.isEmpty ? nil : category)
            }

            // The row's own line is written too, above, even when the rule now says the same
            // thing. Both are needed: the rule covers every other row from this merchant, and
            // the line covers *this* one, which may already have carried a different category
            // that no amount of rewriting a rule could dislodge — specificity wins.
            if rememberForMerchant, !category.isEmpty, !ruleMerchant.isEmpty {
                try ledger.setMerchantRule(merchant: ruleMerchant, label: category)
            }
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
            // Names the bank, not the Balance — though a payment moves both, money out of the
            // bank and the same amount off what is owed. The bank is the one with nowhere else
            // to read it: the Balance is on the summary row directly behind this sheet.
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

    // MARK: - Deleting the raw line

    private func reloadJournalLink() {
        guard let editing else { return }
        journalLink = ledger.journalLink(for: editing)
    }

    /// Deletes the invocation this row came from, and the row with it.
    ///
    /// The journal is written first, exactly as it is from the feed and the Raw journal. If that
    /// half lands and the store save fails, the sheet does **not** stay editable: the capture
    /// line is already gone, and a save from here would append an instruction naming an
    /// occurrence no rebuild can produce. That state is terminal — the caller closes the sheet
    /// and reports it in the feed's deletion banner, where the same remedy (swipe the row) is
    /// already offered.
    private func deleteJournalLine(_ record: JournalRecord) {
        pendingJournalDeletion = nil
        journalDeletionError = nil

        do {
            let result = try ledger.deleteJournalInvocation(runID: record.runID)

            if result.lines > 0 {
                if let saveError = result.saveError {
                    finishDeletion(problem: "The line is gone from the journal, but the ledger "
                        + "could not be updated: \(saveError) Swipe the transaction in the feed "
                        + "to remove it.")
                } else {
                    finishDeletion(problem: nil)
                }
                return
            }

            if let saveError = result.saveError {
                // Nothing left the journal, and the store refused too. The row and its line are
                // both still there, so the form stays usable.
                journalDeletionError = "Nothing was deleted. \(saveError)"
                reloadJournalLink()
                return
            }

            if result.rows > 0 {
                // The line had already gone, but the row it left behind has now been removed.
                finishDeletion(problem: nil)
            } else {
                journalDeletionError = "Nothing was deleted. The line is no longer in the journal."
                reloadJournalLink()
            }
        } catch {
            // The journal was not rewritten, so nothing changed and the form is still safe.
            journalDeletionError = error.localizedDescription
            reloadJournalLink()
        }
    }

    /// Ends the sheet after the line, and possibly the row, has gone.
    ///
    /// The guard state is set before the caller is told, so a render that arrives while the
    /// presentation is being torn down cannot read the deleted model. `dismiss()` is a fallback
    /// for a caller that does not clear the presentation item itself.
    private func finishDeletion(problem: String?) {
        journalWasDeleted = true
        onDeleted(problem)
        dismiss()
    }

    private func verb(for minor: Int) -> String { minor < 0 ? "Subtracted" : "Added" }

    private func magnitude(of minor: Int) -> Int { minor < 0 ? -minor : minor }

    private func formatted(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.currency(code: "USD"))
    }
}
