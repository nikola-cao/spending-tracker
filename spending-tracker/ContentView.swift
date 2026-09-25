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

    /// The rows in the order the feed shows them. See `Txn.feedOrder`.
    private var orderedTransactions: [Txn] { Txn.feedOrder(transactions) }

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
    private var monthSpend: (total: String, name: String) {
        let calendar = Calendar.current
        let now = Date()
        let thisMonth = transactions.filter {
            !$0.isDeposit && calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month)
        }
        let minor = thisMonth.reduce(0) { $0 + $1.amountMinor }
        return (
            total: (Decimal(minor) / 100).formatted(.currency(code: "USD")),
            name: now.formatted(.dateTime.month(.wide).year())
        )
    }

    private var formattedBankBalance: String {
        (Decimal(bankBalanceMinor) / 100).formatted(.currency(code: "USD"))
    }

    /// Two figures: what has been spent this month, and what is in the bank. Each is written
    /// out as a plain `Text` rather than through a shared helper — a helper returning a
    /// different view per branch is exactly the kind of multi-branch builder that blows the
    /// type checker's time budget here, and there are only two of them.
    private var totalSpendSection: some View {
        let spend = monthSpend
        return Section {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spend.total)
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("Balance")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                // The bank balance is the only figure that can be edited, so it is the only
                // one that is a control. A row-wide tap that opened a bank editor from the
                // spend figure would be a surprise.
                Button {
                    isShowingBankBalance = true
                } label: {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(formattedBankBalance)
                            .font(.title.weight(.semibold))
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("Bank")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("Bank balance")
                .accessibilityValue(formattedBankBalance)
                .accessibilityHint("Change the amount in the bank")
            }
            .padding(.vertical, 4)
        } header: {
            Text(spend.name)
        }
    }

    // MARK: - Ledger

    @ViewBuilder
    private var transactionsSection: some View {
        if transactions.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No transactions yet", systemImage: "creditcard")
                } description: {
                    Text("Alerts captured by the automation, and anything you add by hand, "
                         + "will appear here.")
                }
            }
        } else {
            // Bound once and used for both the rows and the offsets, so a swipe can only ever
            // resolve against the array that was actually drawn. Two evaluations of
            // `orderedTransactions` could disagree, and then the swipe deletes the wrong row.
            let rows = orderedTransactions
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

    /// Hoisted out of the `ViewBuilder`: an interpolated ternary inside one is what blows the
    /// type checker's time budget.
    private var transactionsHeader: String {
        let noun = transactions.count == 1 ? "transaction" : "transactions"
        return "\(transactions.count) \(noun)"
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
                .foregroundStyle(.primary)
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
