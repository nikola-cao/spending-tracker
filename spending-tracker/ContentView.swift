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
    @Query(sort: [SortDescriptor(\Txn.occurredAt, order: .reverse)])
    private var transactions: [Txn]

    /// Alerts that arrived but did not resolve to a charge: an unparseable body, or a verb
    /// that is not "charged". Kept visible rather than dropped, because the whole point of
    /// the parser rejecting ambiguous input is that the rejection should be *seen*.
    @Query(
        filter: #Predicate<AlertEvent> { $0.transaction == nil },
        sort: [SortDescriptor(\AlertEvent.receivedAt, order: .reverse)]
    )
    private var unresolved: [AlertEvent]

    @State private var lastCapture: Date?
    @State private var isShowingJournal = false

    var body: some View {
        NavigationStack {
            List {
                freshnessSection
                if !unresolved.isEmpty { needsReviewSection }
                transactionsSection
            }
            .navigationTitle("Spending")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingJournal = true
                    } label: {
                        Label("Raw journal", systemImage: "doc.text.magnifyingglass")
                    }
                }
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
        ledger.drain()
        // Read from the journal rather than the store: this answers "is capture still
        // working", which must not depend on the drain having succeeded.
        lastCapture = JournalStore.readAll(from: JournalLocation.fileURL).last?.receivedAt
    }

    // MARK: - Freshness
    //
    // Signing expires every 7 days on a free Apple ID, and when it does the Shortcut still
    // fires while the App Intent quietly never runs. Capture stops with no error anywhere.
    // This banner is the only thing that makes that visible.

    private var staleness: (text: String, isStale: Bool) {
        guard let lastCapture else { return ("No alerts captured yet", true) }
        let hours = Date().timeIntervalSince(lastCapture) / 3600
        return ("Last capture: \(lastCapture.formatted(.relative(presentation: .named)))", hours > 48)
    }

    private var freshnessSection: some View {
        Section {
            HStack(spacing: 8) {
                Image(systemName: staleness.isStale
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(staleness.isStale ? Color.red : Color.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(staleness.text).font(.subheadline.weight(.medium))
                    if staleness.isStale {
                        Text("Nothing captured in over 48 hours. Re-sign the app from Xcode "
                             + "(⌘R), then check the automation is still enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listRowBackground(staleness.isStale ? Color.red.opacity(0.10) : nil)
    }

    // MARK: - Ledger

    @ViewBuilder
    private var transactionsSection: some View {
        if transactions.isEmpty {
            Section {
                ContentUnavailableView {
                    Label("No charges yet", systemImage: "creditcard")
                } description: {
                    Text(unresolved.isEmpty
                         ? "Alerts captured by the automation will appear here."
                         : "Alerts arrived but none could be read as a charge.")
                }
            }
        } else {
            Section {
                ForEach(transactions) { txn in
                    TxnRow(txn: txn)
                }
            } header: {
                Text(chargesHeader)
            }
        }
    }

    /// Hoisted out of the `ViewBuilder`: an interpolated ternary inside one is what blows the
    /// type checker's time budget.
    private var chargesHeader: String {
        let noun = transactions.count == 1 ? "charge" : "charges"
        return "\(transactions.count) \(noun)"
    }

    private var needsReviewSection: some View {
        Section {
            ForEach(unresolved) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.body)
                        .font(.footnote.monospaced())
                        .lineLimit(4)
                    Text(event.receivedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Label("\(unresolved.count) not read as a charge", systemImage: "questionmark.circle")
        } footer: {
            Text("The raw text is kept, so a parser fix can recover these.")
                .font(.caption2)
        }
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
        var parts = ["••\(txn.cardLast4)", txn.occurredAt.formatted(date: .abbreviated, time: .shortened)]
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
                            Text(record.phase == "enter" ? "▸ enter" : "✓ result")
                                .font(.caption.bold())
                                .foregroundStyle(record.phase == "enter" ? Color.orange : Color.green)
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
