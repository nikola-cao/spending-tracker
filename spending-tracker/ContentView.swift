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

    @State private var isShowingJournal = false
    @State private var isShowingManualEntry = false
    @State private var isShowingDiagnostics = false
    @State private var saveError: String?

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
    private var monthSpend: (total: String, count: Int, name: String) {
        let calendar = Calendar.current
        let now = Date()
        let thisMonth = transactions.filter {
            calendar.isDate($0.occurredAt, equalTo: now, toGranularity: .month)
        }
        let minor = thisMonth.reduce(0) { $0 + $1.amountMinor }
        return (
            total: (Decimal(minor) / 100).formatted(.currency(code: "USD")),
            count: thisMonth.count,
            name: now.formatted(.dateTime.month(.wide).year())
        )
    }

    private var totalSpendSection: some View {
        let spend = monthSpend
        return Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(spend.total)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                // Hoisted: an interpolated ternary inside a ViewBuilder is what blows the
                // type checker's time budget.
                Text(spend.count == 1 ? "1 charge" : "\(spend.count) charges")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Label("No charges yet", systemImage: "creditcard")
                } description: {
                    Text("Alerts captured by the automation will appear here.")
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
                }
                .onDelete { offsets in
                    deleteTransactions(at: offsets, in: rows)
                }
            } header: {
                Text(chargesHeader)
            } footer: {
                Text("Swipe a charge to delete it. Deleting also removes it from the raw "
                     + "journal, so it will not come back.")
            }
        }
    }

    /// Deleting a charge has to remove its journal line too — the store is derived, and the
    /// next drain would otherwise recreate the row from the journal within seconds.
    private func deleteTransactions(at offsets: IndexSet, in rows: [Txn]) {
        ledger.delete(offsets.map { rows[$0] })
    }

    /// Hoisted out of the `ViewBuilder`: an interpolated ternary inside one is what blows the
    /// type checker's time budget.
    private var chargesHeader: String {
        let noun = transactions.count == 1 ? "charge" : "charges"
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
        // A charge may have no card at all — a hand-entered one where the card was left blank
        // — so the bullet is omitted rather than shown with nothing after it.
        if !txn.cardSuffix.isEmpty { parts.append("••\(txn.cardSuffix)") }
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
