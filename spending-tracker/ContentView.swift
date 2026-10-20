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

    /// The classification pass. Inert without a key in the keychain, which is why nothing here
    /// has to ask whether it is configured — see `CategoryEngine.clientFromKeychain`.
    ///
    /// Owned by the app rather than by this view: the view is rebuilt on every render, and a
    /// pass that was under way would go with it.
    let categorizer: CategoryEngine

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

    /// Which category the list is narrowed to. `nil` is every category.
    ///
    /// View state, like `selectedMonth`, and never stored: which slice of the feed you are
    /// looking at is not a fact about your money, and a filter that survived a relaunch would
    /// make the screen open on a partial month with nothing on it saying so.
    ///
    /// `""` is **Uncategorized**, which is a real choice rather than the absence of one — the
    /// rows the classifier has not answered for yet. Held as the token the row carries rather
    /// than as an enum, so it agrees with the journal by construction.
    @State private var categoryFilter: String?

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

    /// The rows the list draws: the month's, narrowed to one category.
    ///
    /// Filtered here rather than in the `@Query`, for the same reason the month is — a predicate
    /// would have to be rebuilt every time the choice changed, and the ordering has to be applied
    /// in Swift anyway.
    ///
    /// **The month's spending, and the three positions under it, deliberately do not read this.**
    /// They read `monthTransactions`, so choosing a category cannot restate any of them: a
    /// Balance narrowed to dining sitting above an unfiltered Bank would make `Remaining` — the
    /// bank less what the cards owe — mean nothing at all. What one category cost is answered by
    /// the subtotal in the list's own header, which is the figure that is honestly about the rows
    /// below it.
    ///
    /// A **payment** matches no category, `Uncategorized` included: a card payoff is not a
    /// purchase, and sweeping it into the unfiled pile would make that pile mean two different
    /// things at once. A **deposit** does match — a person-to-person payment's note names what
    /// it was for — so a Venmo for dinner shows under Dining, because its deposit *is* the
    /// purchase from the user's side.
    private var feedRows: [Txn] {
        guard let categoryFilter else { return monthTransactions }
        return monthTransactions.filter {
            $0.isCategorizable && $0.categoryRaw == categoryFilter
        }
    }

    /// What the filtered rows add up to, by the same rule the month's spending uses.
    ///
    /// `Txn.spendingTotal`, not a local sum. With deposits categorisable, a Venmo you *sent* for
    /// dinner is money out and belongs in the figure, while one you *received* is money in and
    /// does not — which is exactly the rule the month's total already encodes. Writing a second
    /// hand-rolled filter here is how the two would come to disagree.
    private var filteredSubtotal: String {
        formatted(Txn.spendingTotal(feedRows))
    }

    /// A checkmark rather than a disabled row, matching the month picker above it, so the
    /// current choice is visible without making it un-tappable.
    @ViewBuilder
    private func filterChoice(_ title: String, isOn: Bool) -> some View {
        if isOn {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    /// What the filter is currently showing, for the menu.
    private var filterLabel: String {
        guard let categoryFilter else { return "All categories" }
        return categoryFilter.isEmpty ? "Uncategorized" : SpendingCategory.displayName(for: categoryFilter)
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

    /// What is owed on the cards, mirrored from the store the same way and for the same reason.
    ///
    /// Two mirrors rather than one net figure because they are two different claims: the store
    /// folds them from separate lines and a change to either arrives here on its own.
    @State private var cardBalanceMinor = 0

    @State private var isShowingJournal = false
    @State private var isShowingManualEntry = false
    @State private var isShowingDiagnostics = false
    @State private var isShowingCategorizationSettings = false
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
                            categoryFilter = nil
                        } label: {
                            filterChoice("All categories", isOn: categoryFilter == nil)
                        }
                        Button {
                            categoryFilter = ""
                        } label: {
                            filterChoice("Uncategorized", isOn: categoryFilter == "")
                        }
                        Divider()
                        ForEach(SpendingCategory.all, id: \.self) { token in
                            Button {
                                categoryFilter = token
                            } label: {
                                filterChoice(SpendingCategory.displayName(for: token),
                                             isOn: categoryFilter == token)
                            }
                        }
                    } label: {
                        // Filled while a filter is on. A list silently showing a third of the
                        // month is the one state that has to be visible from the toolbar, since
                        // nothing else on the screen would say the rest of it exists.
                        Label("Filter", systemImage: categoryFilter == nil
                            ? "line.3.horizontal.decrease.circle"
                            : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityIdentifier("Category filter")
                    .accessibilityValue(filterLabel)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isShowingCategorizationSettings = true
                        } label: {
                            Label("AI categorization", systemImage: "sparkles")
                        }
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
            .sheet(isPresented: $isShowingCategorizationSettings) {
                CategorizationSettingsView(ledger: ledger, categorizer: categorizer)
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
            // The initial drain, and — when the view appears already active — the pass as well.
            //
            // The scene-phase handler below is the normal trigger, but it fires on a
            // *transition*. A view that first appears in `.active` observes no change, and would
            // drain the journal and then leave every new row uncategorized until the user
            // backgrounded the app or pulled to refresh — while the settings screen promises a
            // pass whenever the app comes to the front. The guard is on the phase rather than
            // unconditional because a background launch servicing the capture intent can reach
            // this view, and a pass with no user present is not something to start by accident.
            // `run()` is single-flight, so the two paths cannot classify twice.
            .task {
                refresh()
                if scenePhase == .active { classify() }
            }
            // Draining on foreground is what turns the raw journal into ledger rows. It is
            // idempotent, so it is safe to run on every activation, and it doubles as the
            // self-healing path: anything the intent wrote while the app was closed is picked
            // up here.
            //
            // The classification pass rides along, after the drain rather than inside it — see
            // `CategoryEngine` for why it is not part of the drain itself. It is fire and forget:
            // nothing on this screen waits for an answer, because the rows it will file are
            // already drawn and simply say they have no category yet.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    refresh()
                    classify()
                }
            }
            .refreshable {
                refresh()
                classify()
            }
            // Started and torn down with the view. An `NWPathMonitor` left running would hold a
            // callback alive for a screen that is gone, and its updates would drive passes from
            // a view nobody is looking at.
            .onAppear { categorizer.startWatchingConnectivity() }
            .onDisappear { categorizer.stopWatchingConnectivity() }
        }
    }

    private func refresh() {
        saveError = ledger.drain().saveError
        bankBalanceMinor = ledger.bankBalanceMinor
        cardBalanceMinor = ledger.cardBalanceMinor
    }

    /// Starts a classification pass without waiting for it.
    ///
    /// Deliberately not awaited, and deliberately not bound to the pull-to-refresh spinner. A
    /// pass can take as long as the network takes, and nothing here is waiting on an answer — the
    /// rows it will file already exist and already render. Making the gesture spin until a third
    /// party replies would turn opening the app into waiting for one.
    private func classify() {
        Task { await categorizer.run() }
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

    /// What the month cost — everything that left, by whatever route it took.
    ///
    /// The month is `occurredAt`'s, the best-known time of the purchase: the date printed in
    /// the Amex email and the Fidelity payment text, and the alert's arrival for the Fidelity
    /// charge text, which carries no date at all.
    /// Deliberately NOT `receivedAt`, which is when we heard about it — a charge that arrives
    /// late still belongs to the month it was made in.
    ///
    /// Which rows count, and why, is `Txn.spendingTotal` — stated once, in the model, where a
    /// test can reach it. This property is only the month, and the fact that it is the one
    /// figure on this screen that is month-scoped at all.
    ///
    /// No charge count here. It was one line of redundancy with the list's own header, which
    /// states the same number directly above the rows it counts.
    private var monthSpendingMinor: Int { Txn.spendingTotal(monthTransactions) }

    /// No month in the name any more. The section header that carried it is gone — the title at
    /// the top of the screen says which month this is, and saying it twice within two inches
    /// was the whole complaint.
    private var monthSpending: String { formatted(monthSpendingMinor) }

    /// What is owed on the cards and not yet paid off, as the journal states it.
    ///
    /// Cumulative rather than month-scoped, and that is deliberate: a card balance is a
    /// *position*, not an event. It is also what makes the rollover happen with no code written
    /// for it — this month's figure is last month's, plus this month's charges, less this
    /// month's payments, because that is simply what folding the journal says. Nothing is
    /// carried across a month boundary by hand, so nothing can be carried wrongly.
    ///
    /// Derived, like `bankBalanceMinor` and for the same reason: it has to survive a rebuild.
    /// See `LedgerStore.setCardBalance` for why a hand-set value is still the only way to state
    /// it — the app knows what it saw charged, never what it missed.
    private var cardBalance: String { formatted(cardBalanceMinor) }

    private var formattedBankBalance: String { formatted(bankBalanceMinor) }

    /// The bank less what is owed on the cards — what you would have if you cleared them.
    ///
    /// Both halves are positions read at the same moment, which is what makes this a figure
    /// rather than the difference between two things measured at different times.
    ///
    /// It moves for both halves without either being folded into the other: a charge raises the
    /// card balance and lowers this, money arriving raises the bank and this. A deposit leaving
    /// the bank lowers it. And a payment lowers *both* at once, so it leaves this exactly where
    /// it was — which is right, because settling a debt does not change what you have.
    ///
    /// Deposits reach it through the bank, never through the spend. A Zelle received is not a
    /// negative cost, and counting it into the month's spending would make a heavy month look
    /// cheap — see `Txn.spendingTotal`, which is where that rule actually lives.
    private var remaining: String { formatted(bankBalanceMinor - cardBalanceMinor) }

    private func formatted(_ minor: Int) -> String {
        (Decimal(minor) / 100).formatted(.currency(code: "USD"))
    }

    /// The month's spending stated on its own, and beneath it the three positions.
    ///
    /// Its own row rather than a fourth column, because it answers a different kind of question
    /// from the three below. Those are where you stand; this is what happened. Three of them are
    /// peers of each other and the fourth is not, and four currency strings across an iPhone
    /// would not fit — shrinking all four to force it would cost the three that belong together
    /// for the sake of the one that does not.
    private var totalSpendSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Text(monthSpending)
                    .font(.largeTitle.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("This Month's Spending")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            // Three equal columns rather than spacers, because `Remaining` is a peer of the
            // other two and not an afterthought hanging off the right edge.
            //
            // The type is one step down from the two-figure version. Three currency strings do
            // not fit across an iPhone at `.title`, and shrinking all three is better than
            // shrinking one.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                // Deliberately not a control, unlike Bank beside it. The card balance is set the
                // same way the bank balance is — by writing a line into the raw journal — but
                // there is no sheet behind this one, so a tap here would open nothing. A figure
                // that looks tappable and is not is worse than one that plainly is not.
                summaryFigure(title: "Balance", value: cardBalance, alignment: .leading)
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
        if feedRows.isEmpty {
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
            // `feedRows` could disagree, and then the swipe deletes the wrong row.
            let rows = feedRows
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
        let noun = feedRows.count == 1 ? "transaction" : "transactions"
        let count = "\(feedRows.count) \(noun)"
        // Only while a filter is on. The subtotal is the honest answer to "what did dining cost
        // this month", and it belongs on the rows it is about rather than on the figures above
        // them, which stay a statement about the whole month whatever is being shown.
        return categoryFilter == nil ? count : "\(count) · \(filteredSubtotal)"
    }

    /// Kept distinct from the genuinely-empty case. An empty month with a full store behind it
    /// saying "no transactions yet" would look like everything had been thrown away — and this
    /// is exactly the moment the month rolls over, when it would be wrong.
    ///
    /// A third case now, for the same reason: an empty *filter* over a month that is full. Left
    /// to fall through it would say "Nothing in October yet" about a month with thirty
    /// transactions in it, which reads as the app having lost them.
    private var emptyTitle: String {
        if categoryFilter != nil, !monthTransactions.isEmpty {
            return categoryFilter == ""
                ? "Nothing uncategorized in \(monthName)"
                : "Nothing in \(filterLabel) in \(monthName)"
        }
        return transactions.isEmpty ? "No transactions yet" : "Nothing in \(monthName) yet"
    }

    private var emptyMessage: String {
        if categoryFilter != nil, !monthTransactions.isEmpty {
            let noun = monthTransactions.count == 1 ? "transaction" : "transactions"
            return "\(monthName) has \(monthTransactions.count) \(noun), and none of them are "
                + "in this category. The filter is hiding them, not a month with nothing in it."
        }
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
        // bare timestamp reads as the transaction time either way. Amex and a Fidelity payment
        // text print a real date; the Fidelity charge text carries none, so there it can only
        // be arrival — and arrival is a weaker signal for email, which Apple Mail fetches on a
        // schedule rather than by push. A date-only source shows a date only. Printing "at
        // 12:00 AM" would invent a time the message never stated, which is exactly the kind of
        // plausible-looking wrong detail this project keeps refusing to make up.
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
        // What it is filed under, next to where the money moved rather than buried at the end
        // beside the date — it is the attribute the list is scanned for.
        //
        // Only a charge shows anything here, and a charge with no category says so in words.
        // A payment or a deposit shows nothing at all rather than "Uncategorized": they are not
        // waiting on an answer, and printing one would suggest the app had failed to give it.
        if txn.isCategorizable {
            parts.append(txn.hasCategory ? txn.categoryName : "Uncategorized")
        }
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

    /// Everything the file holds: the records, and — separately — the lines that could not be
    /// read back. Kept as one value rather than as two `@State` arrays because they are two
    /// halves of one read, and two reads can disagree.
    @State private var journal = JournalRead()

    /// The line a swipe is asking about. The swipe is not the decision: this screen destroys
    /// the app's source of truth, and the dialog is the one place the user is told what else
    /// goes with the line they picked.
    ///
    /// One dialog for both kinds of line. A damaged line is not a `JournalRecord` — nothing can
    /// read it — but it is a line of the same file, removed by the same swipe, and two dialogs
    /// with two sets of words for one gesture would be two things to keep in step.
    @State private var pendingDeletion: PendingDeletion?

    enum PendingDeletion: Identifiable {
        case record(JournalRecord)

        /// A line nothing can read, addressed by the bytes it holds. The same identity the
        /// deletion uses, since a position in the file is not a name that survives a rewrite.
        case damaged(Data)

        var id: String {
            switch self {
            case .record(let record): record.id.uuidString
            case .damaged(let bytes): "damaged-\(bytes.count)-\(bytes.hashValue)"
            }
        }
    }

    @State private var errorMessage: String?
    @State private var note: String?

    var body: some View {
        // Bound once, exactly as the feed binds its rows, so the offsets a swipe reports can
        // only ever be resolved against the array that was actually drawn.
        let shown = Array(journal.records.reversed())

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
                    pendingDeletion = .record(shown[index])
                }
            } header: {
                Text("\(journal.records.count) lines · newest first")
            } footer: {
                Text("Swipe a line to delete it. The ledger is rebuilt by replaying this file, so "
                     + "a line and the transaction it recorded go together — a row whose line is "
                     + "gone would only come back.")
            }

            // Last, not first: a damaged line has no timestamp, and a torn write is the tail of
            // the file in every case that has been seen. Shown at all because not showing it is
            // what made "written and unreadable" look exactly like "never arrived".
            if !journal.damaged.isEmpty {
                Section {
                    ForEach(journal.damaged, id: \.self) { bytes in
                        DamagedRow(bytes: bytes)
                    }
                    .onDelete { offsets in
                        guard let index = offsets.first,
                              journal.damaged.indices.contains(index) else { return }
                        pendingDeletion = .damaged(journal.damaged[index])
                    }
                } header: {
                    Text("\(journal.damaged.count) damaged · cannot be read")
                } footer: {
                    Text("These lines are in the file and cannot be decoded — an append that was "
                         + "interrupted, or a record shape from another version of the app. No "
                         + "transaction was derived from them and nothing else records what they "
                         + "held. Swipe to remove one.")
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
        .task { reload() }
        .confirmationDialog(
            "Delete this journal line?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            // Deliberately not "Delete": the swipe action behind this dialog already owns that
            // label, and two buttons with one name is a coin toss for a person and ambiguous
            // for anything reading the screen.
            Button("Delete line", role: .destructive) { delete(pending) }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { pending in
            switch pending {
            case .record(let record):
                // What else goes is read from the STORE, not from the text. The two can disagree:
                // a body that parsed when it was ingested and no longer does still owns its row,
                // and the copy must not promise otherwise.
                Text(record.outcome.message(storedRows: ledger.rowsRecorded(by: record)))
            case .damaged(let bytes):
                Text(Self.damagedMessage(bytes))
            }
        }
    }

    /// What deleting a damaged line takes away: nothing derived, and the only copy of whatever
    /// the bytes hold.
    ///
    /// Worded so nobody waits for a transaction to disappear — this is precisely the case where
    /// there is none, and a confirmation that hinted otherwise would be the one place the app
    /// misdescribes what it is holding.
    private static func damagedMessage(_ bytes: Data) -> String {
        "This line is in the journal and cannot be decoded, so nothing in the ledger was ever "
        + "derived from it and no transaction changes. It is the only copy of the "
        + "\(bytes.count) bytes it holds. This cannot be undone."
    }

    private func reload() {
        journal = JournalStore.read(from: JournalLocation.fileURL)
    }

    private func delete(_ pending: PendingDeletion) {
        switch pending {
        case .record(let record): deleteRecordLine(record)
        case .damaged(let bytes): deleteDamagedLine(bytes)
        }
    }

    /// The one deletion with only a journal half: nothing could read the line, so nothing was
    /// ever derived from it and there is no row to remove.
    private func deleteDamagedLine(_ bytes: Data) {
        pendingDeletion = nil
        errorMessage = nil
        note = nil

        do {
            let result = try ledger.deleteDamagedLine(bytes)
            reload()
            onChanged()
            note = result.lines > 0
                ? "Damaged line deleted. Nothing in the ledger was derived from it — nothing "
                    + "could read it."
                : "Nothing was deleted."
        } catch {
            // The journal could not be rewritten, so the line is still there — reload rather
            // than leave the screen showing what it showed before the attempt.
            reload()
            onChanged()
            errorMessage = error.localizedDescription
        }
    }

    private func deleteRecordLine(_ record: JournalRecord) {
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
            // Says "Bank balance", not "Balance". That word now names the card figure on the
            // summary row, so the old wording would have been a note about the wrong one.
            return "Bank balance line deleted. The Bank figure is restated from what is left."
        case .instruction(.setCardBalance):
            return "Card balance line deleted. The Balance figure is restated from what is left."
        case .instruction(.edit):
            return "Edit line deleted. The row it changed reads as the original line said."
        case .instruction(.category):
            return "Category line deleted. That transaction takes whatever else applies to its merchant."
        case .instruction(.merchantCategory(let rule)):
            return "Merchant rule deleted. Everything from \"\(rule.merchant)\" falls back to "
                + "whatever else applies, and that merchant can be asked about again."
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

    /// True when this line was not written by this app, into this app's own container.
    ///
    /// Every line records the process that wrote it and the journal directory it went to, for
    /// exactly this: a write that landed somewhere the app cannot read is the one failure that
    /// loses an alert with no other trace anywhere. Nothing rendered those fields until now,
    /// which made an instrument that could not be read — the answer was in the file, and
    /// unreachable from the phone.
    private var writtenElsewhere: Bool {
        record.processName != RuntimeFacts.processName()
            || record.journalDirectory != JournalLocation.directoryPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // No phase chip: one line per alert now, so it would say the same thing on
                // every row. Older journals still hold an enter/result pair and simply read
                // as two lines with the same body.
                Text(record.receivedAt, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if writtenElsewhere {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.red)
                }
                Spacer()
                Text(record.processName)
                    .font(.caption)
                    .foregroundStyle(writtenElsewhere ? Color.red : Color.secondary)
                Text("\(record.charCount) ch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(record.rawText).font(.footnote.monospaced())
        }
        .padding(.vertical, 2)
    }
}

/// A line that is in the journal and cannot be read back.
///
/// Shown rather than hidden, and that is the whole point of the row. Dropping it from the read
/// was what made **"a line was written and cannot be decoded"** — the one state where a
/// transaction disappears with no trace on any screen — look exactly like **"no alert ever
/// arrived"**. The bytes are printed lossily on purpose: they are the evidence, and a preview
/// that refused to print them would hide the only thing this row exists to show.
private struct DamagedRow: View {
    let bytes: Data

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
                Text("Damaged line")
                    .font(.caption.weight(.medium))
                Spacer()
                Text("\(bytes.count) bytes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(String(decoding: bytes.prefix(400), as: UTF8.self))
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    let ledger = LedgerStore(container: try! ModelContainer(
        for: Schema([AlertEvent.self, Txn.self]),
        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
    ))
    // Inert in the preview: no key is reachable from here, so no pass is ever made.
    return ContentView(ledger: ledger, categorizer: CategoryEngine(ledger: ledger))
}
