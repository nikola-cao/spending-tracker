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

    /// The rows the feed shows: this month only, in the order the feed shows them.
    ///
    /// Both halves recompute on every render and neither is stored, so the month rolls over on
    /// the first render after midnight on the 1st — no timer, no scheduled task, and nothing to
    /// get out of step. See `Txn.inMonth` and `Txn.feedOrder`.
    private var monthTransactions: [Txn] {
        Txn.feedOrder(Txn.inMonth(of: Date(), from: transactions))
    }

    private var monthName: String {
        Date().formatted(.dateTime.month(.wide))
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

    /// The row currently open for editing. `Txn` is `Identifiable` through its persistent id,
    /// so `sheet(item:)` can present on it directly rather than on a separate flag plus a
    /// lookup that could disagree about which row was tapped.
    @State private var editingTxn: Txn?

    var body: some View {
        NavigationStack {
            List {
                totalSpendSection
                saveErrorSection
                transactionsSection
            }
            .navigationTitle("Spending")
            .toolbar {
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
                NavigationStack { JournalView() }
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
    private var monthSpendMinor: Int {
        monthTransactions
            .filter { !$0.isDeposit }
            .reduce(0) { $0 + $1.amountMinor }
    }

    private var monthSpend: (total: String, name: String) {
        (
            total: formatted(monthSpendMinor),
            name: Date().formatted(.dateTime.month(.wide).year())
        )
    }

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
        let spend = monthSpend
        return Section {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                summaryFigure(title: "Balance", value: spend.total, alignment: .leading)
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
        } header: {
            Text(spend.name)
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
                     + "removes it from the raw journal, so it will not come back.")
            }
        }
    }

    /// Deleting a row has to remove its journal line too — the store is derived, and the next
    /// drain would otherwise recreate the row from the journal within seconds.
    ///
    /// Deleting a deposit gives the bank back what it took, and there is nothing to do for
    /// that here: the balance is folded from the journal, so removing the line removes its
    /// effect. The refresh afterwards is what shows the new figure.
    private func deleteTransactions(at offsets: IndexSet, in rows: [Txn]) {
        ledger.delete(offsets.map { rows[$0] })
        refresh()
    }

    /// The month is named here as well as above the total, because this list is no longer
    /// "everything ever" — an unlabelled count with older rows in the store would read as
    /// missing data rather than as a month.
    private var transactionsHeader: String {
        let noun = monthTransactions.count == 1 ? "transaction" : "transactions"
        return "\(monthName) · \(monthTransactions.count) \(noun)"
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
                // Both branches named explicitly. A bare `.primary` against a `Color` is a
                // `HierarchicalShapeStyle` on one side and a `Color` on the other, which does
                // not type-check — the same trap the refuted-write row hit before.
                .foregroundStyle(txn.isMoneyIn ? Color.green : Color.primary)
        }
        .padding(.vertical, 2)
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
        if txn.isDeposit {
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
struct JournalView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var records: [JournalRecord] = []

    var body: some View {
        List {
            Section {
                Text(JournalLocation.directoryPath)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
            Section("\(records.count) lines · newest first") {
                ForEach(Array(records.reversed())) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            // No phase chip: one line per alert now, so it would say the same
                            // thing on every row. Older journals still hold an enter/result
                            // pair and simply read as two lines with the same body.
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
        }
        .navigationTitle("Raw journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { records = JournalStore.readAll(from: JournalLocation.fileURL) }
    }
}

#Preview {
    ContentView(ledger: LedgerStore(container: try! ModelContainer(
        for: Schema([AlertEvent.self, Txn.self]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    )))
}
