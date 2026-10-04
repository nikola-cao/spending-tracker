//
//  ContentView.swift
//  spending-tracker
//
//  The ledger: what was spent, newest first.
//

import Foundation
import SwiftData
import SwiftUI

struct ContentView: View {

    let ledger: LedgerStore

    @Environment(\.scenePhase) private var scenePhase

    /// No predicate. `Txn` holds only parsed charges by construction — an alert that did not
    /// resolve to a charge has no `Txn` at all — so unlike the query below, this cannot
    /// accidentally include something that is not a transaction.
    ///
    /// Sorted by arrival only to give the rows a stable base order; the order the feed
    /// actually uses is imposed by `feedOrder`. That one needs a calendar to reduce each row
    /// to a day, which a `SortDescriptor` cannot express, so it is applied here instead.
    @Query(sort: [SortDescriptor(\Txn.receivedAt, order: .reverse)])
    private var transactions: [Txn]

    /// Which month the whole screen is showing. Seeded to the current one, and reset to it on
    /// every launch — looking back is something you ask for, not a state to get stuck in.
    @State private var selectedMonth = Date()

    /// The months the picker offers: this one, and the five before it.
    private var selectableMonths: [Date] {
        Txn.monthsEnding(with: Date(), count: 6)
    }

    /// The rows the feed shows: the selected month only, in the order the feed shows them.
    ///
    /// Both halves recompute on every render and neither is stored, so the month rolls over on
    /// the first render after midnight on the 1st — no timer, no scheduled task, and nothing to
    /// get out of step. See `Txn.inMonth` and `Txn.feedOrder`.
    private var monthTransactions: [Txn] {
        Txn.feedOrder(Txn.inMonth(of: selectedMonth, from: transactions))
    }

    private var monthName: String {
        selectedMonth.formatted(.dateTime.month(.wide))
    }

    /// Both the title and the picker's own rows read the same way, so what is selected is
    /// word-for-word what the list below is showing.
    private func monthLabel(_ month: Date) -> String {
        // The year only where it is ambiguous. Within the six-month window it is ambiguous
        // exactly once — in January, when the list runs back into December.
        month.formatted(.dateTime.month(.wide).year())
    }

    /// The bank balance, mirrored from the store.
    ///
    /// A `@State` copy rather than a binding, because there is nothing here to bind *to*: the
    /// balance is derived by folding the journal, so it is read out of the store after every
    /// drain and never written back. Anything that changes it writes a journal line and
    /// re-drains, which is what makes a rebuild restore it.
    @State private var bankBalanceMinor = 0

    @State private var isShowingJournal = false
    @State private var isShowingManualEntry = false
    @State private var isShowingDiagnostics = false
    @State private var isShowingBankBalance = false
    @State private var saveError: String?

    /// A deletion that could not be finished. Its own state rather than sharing `saveError`,
    /// because the two mean different things and the drain's reassurance ("nothing is lost —
    /// the raw journal is intact") is not true of a deletion: the line is exactly what is gone.
    @State private var deletionError: String?

    /// The row currently open for editing. `Txn` is `Identifiable` through its persistent id,
    /// so `sheet(item:)` can present on it directly rather than on a separate flag plus a
    /// lookup that could disagree about which row was tapped.
    @State private var editingTxn: Txn?

    var body: some View {
        NavigationStack {
            List {
                totalSpendSection
                saveErrorSection
                deletionErrorSection
                transactionsSection
            }
            .navigationTitle("\(monthName) Spending")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The title itself is the picker. A `.principal` item replaces the navigation
                // title, so the bar's own label goes with it — which is why the UI tests look
                // for this button rather than for `navigationBars["…"]`.
                ToolbarItem(placement: .principal) {
                    Menu {
                        ForEach(selectableMonths, id: \.self) { month in
                            Button {
                                selectedMonth = month
                            } label: {
                                // A checkmark rather than a disabled row, so the current choice
                                // is visible without making it un-tappable.
                                if Calendar.current.isDate(
                                    month, equalTo: selectedMonth, toGranularity: .month) {
                                    Label(monthLabel(month), systemImage: "checkmark")
                                } else {
                                    Text(monthLabel(month))
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(monthName) Spending")
                                .font(.headline)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                    }
                    .accessibilityIdentifier("Month")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingManualEntry = true
                    } label: {
                        Label("Add manually", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingDiagnostics = true
                        } label: {
                            Label("Diagnostics", systemImage: "stethoscope")
                        }
                        Button {
                            isShowingJournal = true
                        } label: {
                            Label("Raw journal", systemImage: "doc.text.magnifyingglass")
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $isShowingManualEntry) {
                ManualEntryView(ledger: ledger) { refresh() }
            }
            .sheet(isPresented: $isShowingDiagnostics) {
                DiagnosticsView(ledger: ledger)
            }
            .sheet(isPresented: $isShowingJournal) {
                NavigationStack { JournalView(ledger: ledger) { refresh() } }
            }
            .sheet(isPresented: $isShowingBankBalance) {
                BankBalanceView(ledger: ledger) { refresh() }
            }
            .sheet(item: $editingTxn) { txn in
                ManualEntryView(ledger: ledger, editing: txn) { refresh() }
            }
            .task { refresh() }
            // Draining on foreground is what turns the raw journal into ledger rows. It is
            // idempotent, so it is safe to run on every activation, and it doubles as the
            // self-healing path: anything the intent wrote while the app was closed is picked
            // up here.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .refreshable { refresh() }
        }
    }

    private func refresh() {
        saveError = ledger.drain().saveError
        bankBalanceMinor = ledger.bankBalanceMinor
    }

    /// A refused write is the one failure that would otherwise render a complete-looking
    /// ledger that is not on disk. It must be visible, not swallowed.
    @ViewBuilder
    private var saveErrorSection: some View {
        if let saveError {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(Color.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("The ledger could not be saved")
                            .font(.subheadline.weight(.medium))
                        Text(saveError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Nothing is lost — the raw journal is intact and this will be "
                             + "retried the next time the app opens.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.red.opacity(0.10))
        }
    }

    /// A deletion that did not complete. Deliberately not folded into `saveErrorSection`: the
    /// reassurance there is that the journal is intact and nothing is lost, and after a
    /// deletion the journal is precisely what has changed.
    @ViewBuilder
    private var deletionErrorSection: some View {
        if let deletionError {
            Section {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("That deletion did not finish")
                            .font(.subheadline.weight(.medium))
                        Text(deletionError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Dismiss") { self.deletionError = nil }
                    .font(.caption)
            }
            .listRowBackground(Color.orange.opacity(0.10))
        }
    }

    // MARK: - Total

    /// What has been spent this calendar month.
    ///
    /// Keyed on `occurredAt`, the best-known time of the purchase — the date printed in the
    /// Amex email, and the alert's arrival for Fidelity, whose SMS carries no date at all.
    /// Deliberately NOT `receivedAt`, which is when we heard about it; a charge that arrives
    /// late still belongs to the month it was made in.
    ///
    /// No charge count here. It was one line of redundancy with the list's own header, which
    /// states the same number directly above the rows it counts.
    ///
    /// Deposits are excluded. This figure is what the month *cost*, and a Zelle received is
    /// not a negative cost — folding it in would make a month of heavy spending look cheap
    /// because someone paid you back for rent. Refunds are a different thing and are not
    /// excluded: a negative charge is money the card gave back on spending that did happen.
    ///
    /// Payments are included, and that is the whole reason they are their own kind. A payment
    /// settles spending that already happened, so it comes off this figure — and it is stored
    /// negative precisely so that summing the month works here without a special case.
    private var monthSpendMinor: Int {
        monthTransactions
            .filter { !$0.isDeposit }
            .reduce(0) { $0 + $1.amountMinor }
    }

    /// No month in the name any more. The section header that carried it is gone — the title at
    /// the top of the screen says which month this is, and saying it twice within two inches
    /// was the whole complaint.
    private var monthSpend: String { formatted(monthSpendMinor) }

    private var formattedBankBalance: String { formatted(bankBalanceMinor) }

    /// The bank less what this month has cost — what is left, in the plainest sense.
    ///
    /// It moves for both halves without either being folded into the other: a charge that
    /// lands lowers it, and so does a deposit leaving the bank, while money coming in raises
    /// it. That is why the two figures above stay separate and this is derived from them
    /// rather than the three being independent numbers that could drift apart.
    ///
    /// Deposits reach it through the bank, not through the spend. A Zelle received is not a
    /// negative cost, and counting it in the Balance would make a heavy month look cheap.
    private var remaining: String { formatted(bankBalanceMinor - monthSpendMinor) }

    private func formatted(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.currency(code: "USD"))
    }

    /// Three figures across: what has been spent this month, what is in the bank, and the
    /// difference between them.
    ///
    /// Three equal columns rather than spacers, because `Remaining` is a peer of the other two
    /// and not an afterthought hanging off the right edge.
    ///
    /// The type is one step down from the two-figure version. Three currency strings do not fit
    /// across an iPhone at `.title`, and shrinking all three is better than shrinking one.
    private var totalSpendSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                summaryFigure(title: "Balance", value: monthSpend, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // The bank balance is the only figure that can be edited, so it is the only one
                // that is a control. A row-wide tap that opened a bank editor from the spend
                // figure would be a surprise.
                Button {
                    isShowingBankBalance = true
                } label: {
                    summaryFigure(title: "Bank", value: formattedBankBalance, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Bank balance")
                .accessibilityValue(formattedBankBalance)
                .accessibilityHint("Change the amount in the bank")

                summaryFigure(title: "Remaining", value: remaining, alignment: .trailing)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
    }

    /// One figure and its label.
    ///
    /// A single return with no branches, which is why it is safe to share here: the type
    /// checker only struggles with builders that produce a different shape per path.
    private func summaryFigure(
        title: String,
        value: String,
        alignment: HorizontalAlignment
    ) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Ledger

    @ViewBuilder
    private var transactionsSection: some View {
        if monthTransactions.isEmpty {
            Section {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "creditcard")
                } description: {
                    Text(emptyMessage)
                }
            }
        } else {
            // Bound once and used for both the rows and the offsets, so a swipe can only ever
            // resolve against the array that was actually drawn. Two evaluations of
            // `monthTransactions` could disagree, and then the swipe deletes the wrong row.
            let rows = monthTransactions
            Section {
                ForEach(rows) { txn in
                    TxnRow(txn: txn)
                        // `onTapGesture` rather than a `Button`: a button merges its label into
                        // one accessibility element, which would hide the merchant and amount
                        // as separate texts — the swipe-to-delete test finds the row by its
                        // merchant string, and so would anything else looking at the list.
                        .contentShape(Rectangle())
                        .onTapGesture { editingTxn = txn }
                }
                .onDelete { offsets in
                    deleteTransactions(at: offsets, in: rows)
                }
            } header: {
                Text(transactionsHeader)
            } footer: {
                Text("Tap a transaction to change it, or swipe it to delete it. Deleting also "
                     + "removes it from the raw journal, so it will not come back. One alert can "
                     + "carry more than one transaction — those go together, because they came "
                     + "from the same line.")
            }
        }
    }

    /// Deleting a row has to remove its journal line too — the store is derived, and the next
    /// drain would otherwise recreate the row from the journal within seconds.
    ///
    /// Deleting a deposit gives the bank back what it took, and there is nothing to do for
    /// that here: the balance is folded from the journal, so removing the line removes its
    /// effect. The refresh afterwards is what shows the new figure.
    ///
    /// Both failures are reported rather than swallowed. A journal that could not be written
    /// means nothing was deleted at all; a store that could not be saved means the row is
    /// still there. Either way the row staying put after a swipe has to look like a failure,
    /// not like the app undoing the delete.
    private func deleteTransactions(at offsets: IndexSet, in rows: [Txn]) {
        do {
            let result = try ledger.delete(offsets.map { rows[$0] })
            deletionError = result.saveError.map {
                "The journal was updated, but the ledger could not be: \($0) "
                    + "The transaction is still listed — swipe it again to remove it."
            }
        } catch {
            deletionError = error.localizedDescription
        }
        refresh()
    }

    /// The count alone. It used to name the month too, back when the month was only stated
    /// above the total and this list could otherwise read as "everything ever" — the title
    /// says it now, directly above.
    private var transactionsHeader: String {
        let noun = monthTransactions.count == 1 ? "transaction" : "transactions"
        return "\(monthTransactions.count) \(noun)"
    }

    /// Kept distinct from the genuinely-empty case. An empty month with a full store behind it
    /// saying "no transactions yet" would look like everything had been thrown away — and this
    /// is exactly the moment the month rolls over, when it would be wrong.
    private var emptyTitle: String {
        transactions.isEmpty ? "No transactions yet" : "Nothing in \(monthName) yet"
    }

    private var emptyMessage: String {
        if transactions.isEmpty {
            return "Alerts captured by the automation, and anything you add by hand, will "
                + "appear here."
        }
        // Says plainly that the history is still there, because the alternative reading is
        // that a month rollover deleted it.
        return "Earlier months are still kept — the list shows one month at a time, and this "
            + "one has not started yet."
    }

}

private struct TxnRow: View {
    let txn: Txn

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(txn.merchant)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(txn.formattedAmount)
                .font(.body.monospacedDigit())
                .foregroundStyle(amountColor)
        }
        .padding(.vertical, 2)
    }

    /// Green for money arriving, red for a payment, ordinary otherwise.
    ///
    /// The payment arm comes first and is not a special case of the other two. `isMoneyIn` asks
    /// the kind before the sign precisely so a payment is not green, and a payment's sign is
    /// negative like a refund's — so a rule written the other way round would have to say
    /// "negative, but not *that* kind of negative" and would get it wrong the moment a fourth
    /// kind appeared.
    ///
    /// Every arm is named explicitly. A bare `.primary` against a `Color` is a
    /// `HierarchicalShapeStyle` on one side and a `Color` on the other, which does not
    /// type-check — the same trap the refuted-write row hit before.
    private var amountColor: Color {
        if txn.isPayment { return .red }
        return txn.isMoneyIn ? .green : .primary
    }

    private var subtitle: String {
        // Labelled by WHERE the time came from, because the two are different claims and a
        // bare timestamp reads as the transaction time either way. Amex prints a real date;
        // the Fidelity SMS carries none, so there it can only be arrival — and arrival is a
        // weaker signal for email, which Apple Mail fetches on a schedule rather than by push.
        // A date-only source shows a date only. Printing "at 12:00 AM" would invent a time the
        // message never stated, which is exactly the kind of plausible-looking wrong detail
        // this project keeps refusing to make up.
        let when: String
        let label: String
        if txn.occurredAtIsFromMessage {
            when = txn.occurredAt.formatted(.dateTime.month(.abbreviated).day().year())
            label = "Purchased"
        } else {
            when = txn.occurredAt.formatted(date: .abbreviated, time: .shortened)
            label = "Alerted"
        }
        var parts: [String] = []
        // Where the money moved, if anywhere. A charge may have no card at all — a hand-entered
        // one where the card was left blank — and a deposit never has one, so the bullet is
        // omitted rather than shown with nothing after it.
        if txn.isPayment {
            parts.append("Payment")
        } else if txn.isDeposit {
            parts.append("Deposit")
        } else if !txn.cardSuffix.isEmpty {
            parts.append("••\(txn.cardSuffix)")
        }
        parts.append("\(label) \(when)")
        if txn.possibleDuplicate { parts.append("possible duplicate") }
        return parts.joined(separator: " · ")
    }
}

/// The raw journal, kept reachable for diagnosis. If the ledger ever disagrees with what was
/// actually received, this is the record that settles it.
///
/// It can also delete a line, which until now was impossible for the lines that produced no
/// transaction: the feed deletes rows, and a body that resolved to nothing — a merchant's own
/// confirmation, an OTP, a statement notice — has no row to swipe.
struct JournalView: View {

    let ledger: LedgerStore

    /// Called after a deletion succeeds, so the feed, the month total and the Bank figure are
    /// all recomputed from the journal that just changed.
    let onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var records: [JournalRecord] = []

    /// The line a swipe is asking about. The swipe is not the decision: this screen destroys
    /// the app's source of truth, and the dialog is the one place the user is told what else
    /// goes with the line they picked.
    @State private var pendingDeletion: JournalRecord?

    @State private var errorMessage: String?
    @State private var note: String?

    var body: some View {
        // Bound once, exactly as the feed binds its rows, so the offsets a swipe reports can
        // only ever be resolved against the array that was actually drawn.
        let shown = Array(records.reversed())

        return List {
            Section {
                Text(JournalLocation.directoryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                        Text(errorMessage)
                            .font(.caption)
                    }
                }
                .listRowBackground(Color.orange.opacity(0.10))
            }

            if let note {
                Section {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(shown) { record in
                    JournalRow(record: record)
                }
                .onDelete { offsets in
                    // The row stays on screen: nothing is removed until the dialog is
                    // confirmed, so a cancelled swipe leaves the journal exactly as it was.
                    guard let index = offsets.first, shown.indices.contains(index) else { return }
                    pendingDeletion = shown[index]
                }
            } header: {
                Text("\(records.count) lines · newest first")
            } footer: {
                Text("Swipe a line to delete it. The ledger is rebuilt by replaying this file, so "
                     + "a line and the transaction it recorded go together — a row whose line is "
                     + "gone would only come back.")
            }
        }
        .navigationTitle("Raw journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { reload() }
        .confirmationDialog(
            "Delete this journal line?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { record in
            // Deliberately not "Delete": the swipe action behind this dialog already owns that
            // label, and two buttons with one name is a coin toss for a person and ambiguous
            // for anything reading the screen.
            Button("Delete line", role: .destructive) { delete(record) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { record in
            // What else goes is read from the STORE, not from the text. The two can disagree:
            // a body that parsed when it was ingested and no longer does still owns its row,
            // and the copy must not promise otherwise.
            Text(record.outcome.message(storedRows: ledger.rowsRecorded(by: record)))
        }
    }

    private func reload() {
        records = JournalStore.readAll(from: JournalLocation.fileURL)
    }

    private func delete(_ record: JournalRecord) {
        let outcome = record.outcome
        pendingDeletion = nil
        errorMessage = nil
        note = nil

        do {
            let result = try ledger.deleteJournalLine(record)
            reload()
            onChanged()

            if let saveError = result.saveError {
                // Which half got done decides what the user is told, and `lines` is what says
                // it: a line already gone with its row left behind is a different problem from
                // a deletion that refused outright, and only the first has a remedy in the feed.
                if result.lines > 0 {
                    errorMessage = "The line is gone from the journal, but the ledger could not "
                        + "be updated: \(saveError) The transaction is still in the feed — swipe "
                        + "it there to remove it."
                } else {
                    errorMessage = "Nothing was deleted. \(saveError)"
                }
            } else {
                note = note(for: outcome, rows: result.rows)
            }
        } catch {
            // The journal could not be rewritten. For an ordinary line that means nothing
            // happened at all; for an edit the row may already be gone and the surviving line
            // will re-derive it on the next drain. The refresh is what settles either case, so
            // the screen ends up showing what the file says rather than what it said before.
            reload()
            onChanged()
            errorMessage = error.localizedDescription
        }
    }

    /// What to say after a deletion that succeeded.
    ///
    /// Derived from the line's own outcome, not from the row count, because the count cannot
    /// tell these apart: deleting a `Bank` line removes no rows but definitely moves the Bank
    /// figure, and deleting an `Edit` line removes a row without removing any transaction — it
    /// re-derives it from the line the edit superseded.
    private func note(for outcome: JournalLineOutcome, rows: Int) -> String {
        switch outcome {
        case .instruction(.setBankBalance):
            return "Balance line deleted. The Bank figure is restated from what is left."
        case .instruction(.edit):
            return "Edit line deleted. The row it changed reads as the original line said."
        case .movement where rows > 1:
            return "Line deleted, with all \(rows) transactions it recorded."
        case .movement:
            return "Line deleted, with the transaction it recorded."
        case .empty, .nothing:
            return rows > 0
                ? "Line deleted, with the record the ledger still held for it."
                : "Line deleted. Nothing in the ledger changed."
        }
    }
}

/// One journal line.
///
/// Extracted for the same reason `TxnRow` is: the row is drawn by two callers' worth of
/// context and the body reads better without it inline. No accessibility merging — the raw
/// text has to stay its own element, which is how both a person with VoiceOver and the UI
/// test find the line they mean.
private struct JournalRow: View {
    let record: JournalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // No phase chip: one line per alert now, so it would say the same thing on
                // every row. Older journals still hold an enter/result pair and simply read
                // as two lines with the same body.
                Text(record.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(record.charCount) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.rawText).font(.footnote.monospaced())
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    ContentView(ledger: LedgerStore(container: try! ModelContainer(
        for: Schema([AlertEvent.self, Txn.self]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )))
}
