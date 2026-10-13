//
//  JournalInstruction.swift
//  spending-tracker
//
//  Journal lines that change stored state instead of recording a movement of money.
//

import Foundation

/// A line in the raw journal that is not an alert.
///
/// Every other line is text a source sent, read by a parser into a `ParsedAlert`. These are
/// the app writing to its own journal, and they exist for one reason: **everything the app
/// knows has to be rebuildable from this file.** The store is deleted and replayed whenever
/// the schema changes, so anything not journalled is lost at the next rebuild — which is what
/// the hand-set bank balance used to be, sitting in `UserDefaults` where the journal could not
/// reach it.
///
/// Kept out of `AlertParsers` deliberately. That registry answers "what did this message
/// mean", and these lines arrived from no message at all. Mixing them in would put
/// instructions in the path that produces ledger rows, where a mis-parse becomes a fake charge.
nonisolated enum JournalInstruction: Equatable {

    /// The user typed a bank balance in. Sets the running balance outright rather than
    /// adjusting it — this is an assertion about the world, not a movement of money.
    case setBankBalance(minor: Int)

    /// The user typed a card balance in — what is owed on the cards and not yet paid off.
    ///
    /// A separate line from the bank balance rather than one net figure, because the two are
    /// different claims and only one of them is true of any given number the user reads off a
    /// statement. They also move for different reasons: a charge raises this and leaves the bank
    /// alone, a deposit raises the bank and leaves this alone.
    ///
    /// **Signed, and positive means owed.** That is the sign the card rows themselves carry — a
    /// charge is stored positive and a payment negative — so a hand-typed balance and the sum of
    /// the rows it supersedes cannot disagree about which way round the number goes. A negative
    /// value is a card in credit, which is a real state and not an error.
    ///
    /// It exists for the same reason `setBankBalance` does, and it is worth stating plainly:
    /// the app cannot work out what is owed. It knows what it has *seen* charged, and the ledger
    /// is incomplete by construction — nothing before the app was installed, a source that only
    /// alerts above a floor, and alerts that never arrived. What it can never know is what those
    /// gaps add up to. This line is the only place that can be said.
    case setCardBalance(minor: Int)

    /// The user changed something already recorded.
    ///
    /// **Appended, never edited in place**, which is the whole reason it carries a key. The
    /// journal is append-only and a captured alert's text is evidence — rewriting a Fidelity
    /// body because the merchant was mistyped would destroy the only record of what the card
    /// actually sent. So the original line stays, and this one supersedes it by naming it.
    ///
    /// The key is the *occurrence* key the ledger already dedupes on — `runID#matchIndex` —
    /// which is what makes this survive a rebuild: the original line is replayed into a row
    /// under the same key, and this line lands on top of it.
    case edit(Edit)

    /// What one transaction is, as the user decided it.
    ///
    /// A **sibling** of `edit` rather than another field on it, and that is not a style choice.
    /// `parseEdit` guards `fields.count == 6` — an equality, not a minimum — so widening that
    /// line by one field would make every `Edit` already in the journal fail to parse, and a
    /// rejected instruction line is invisible: the row would quietly keep the values the user
    /// thought they had changed. A new line kind cannot break an old one.
    ///
    /// A category is not part of what a row *is* the way an amount is, which is the second
    /// reason it is not folded into `edit`: this line says nothing about the four fields next to
    /// it, so a change here can never restate an amount, and a change there can never drop a
    /// category.
    case category(Category)

    /// What every transaction from one merchant is.
    ///
    /// The unit the AI answers in, and the reason a monthly subscription costs one request ever
    /// rather than one a month forever. Kept apart from `category` because the two are different
    /// claims: this one is about a shop, that one is about a single purchase, and a row that the
    /// user has spoken about individually must not be rewritten by a later statement about the
    /// shop. See `LedgerStore.categoryDecisions` for how the two are ranked.
    case merchantCategory(MerchantCategory)

    struct Edit: Equatable {
        let occurrenceKey: String
        let amountMinor: Int

        /// The whole date, or nil to clear it. Never a partial change: the form has one date
        /// field, and "the date is now this" is the only thing it can mean.
        let occurredAt: Date?

        let cardSuffix: String
        let merchant: String
    }

    /// A category on one row, named by the occurrence key that row is already addressed by.
    struct Category: Equatable {
        let occurrenceKey: String

        /// Nil is an **explicit clear**, not a missing value.
        ///
        /// The distinction is the whole reason this is optional. Absent means "this line says
        /// nothing about that row, fall through to the merchant rules"; nil means "the user
        /// decided this row has no category, and no rule may put one back". Collapsing the two
        /// would make it impossible to take a single row out of a merchant rule the user set
        /// deliberately.
        let label: String?

        let source: Source
    }

    /// A category on one merchant.
    struct MerchantCategory: Equatable {
        /// The merchant **exactly as the row spells it**, never a normalised key.
        ///
        /// This is what makes the line rebuildable. `MerchantKey.normalize` is a function, and a
        /// function can be changed; a stored key would be orphaned the moment it was, because
        /// the row would re-derive to something the stored key no longer equals. Storing the
        /// descriptor and normalising on every read means a change to the normaliser re-derives
        /// every rule consistently instead of silently disconnecting them.
        let merchant: String

        let label: String
        let source: Source
    }

    /// Who decided. `user` beats `ai`, always — the model is not allowed to overwrite a person.
    ///
    /// A `String` raw value so the token in the line is the token in the code, the same
    /// arrangement `Txn.kindRaw` uses and for the same reason: the journal line and the type
    /// cannot come to disagree about how a value is spelled.
    enum Source: String, Equatable, Sendable {
        case user
        case ai
    }
}

/// Reads and writes those lines. Same arrangement as every other source: one owner for the
/// format, so the writer and the reader cannot drift apart.
nonisolated enum JournalInstructionParser {

    /// The leading tokens. Each reads plainly in the raw journal, where a person may be looking
    /// straight at it.
    static let bankPrefix = "Bank"
    static let cardPrefix = "Card"
    static let editPrefix = "Edit"
    static let categoryPrefix = "Category"
    static let merchantCategoryPrefix = "MerchantCategory"

    /// Every leading token the app writes to itself, for the retention purge.
    ///
    /// One list, so a new instruction kind cannot be added without the purge learning about it —
    /// which is the failure that would drop a user's decision off the end of the journal a week
    /// later with nothing left to notice it by.
    static let prefixes = [bankPrefix, editPrefix, categoryPrefix, merchantCategoryPrefix]

    private static let delimiter = " | "

    // MARK: - Writing

    /// `Bank | 1234.56`
    ///
    /// The canonical decimal rather than what was typed, for the same reason the other
    /// composers use it: the line has to be re-readable however the amount was written.
    static func composeBankBalance(_ minor: Int) -> String {
        [bankPrefix, Money.decimalString(fromMinor: minor)].joined(separator: delimiter)
    }

    /// `Card | 240.00`
    ///
    /// Same shape and same reasoning as the bank line above, including the canonical decimal:
    /// the line has to be re-readable however the amount was written.
    static func composeCardBalance(_ minor: Int) -> String {
        [cardPrefix, Money.decimalString(fromMinor: minor)].joined(separator: delimiter)
    }

    /// `Edit | <runID>#<index> | <amount> | <yyyy-MM-dd> | <cardSuffix> | <merchant>`
    ///
    /// The merchant is last for the same reason it is last everywhere else: it is free text a
    /// person typed, so it may contain the delimiter, and putting it at the end means nothing
    /// has to be escaped or rejected.
    static func composeEdit(
        occurrenceKey: String,
        merchant: String,
        amount: String,
        date: Date?,
        cardSuffix: String
    ) -> String {
        let fields = [
            editPrefix,
            occurrenceKey,
            amount.trimmingCharacters(in: .whitespacesAndNewlines),
            date.map { DayFormat.string(from: $0) } ?? "",
            cardSuffix.trimmingCharacters(in: .whitespacesAndNewlines),
            merchant.trimmingCharacters(in: .whitespacesAndNewlines),
        ]
        return fields.joined(separator: delimiter)
    }

    /// `Category | <runID>#<index> | <label> | <source>`
    ///
    /// An empty label is the explicit clear, and it is written rather than omitted because the
    /// line has to say *which* row it is clearing — see `JournalInstruction.Category.label`.
    static func composeCategory(
        occurrenceKey: String,
        label: String?,
        source: JournalInstruction.Source = .user
    ) -> String {
        [
            categoryPrefix,
            occurrenceKey,
            label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            source.rawValue,
        ].joined(separator: delimiter)
    }

    /// `MerchantCategory | <label> | <source> | <merchant>`
    ///
    /// The merchant is last for the same reason it is last everywhere else: it is free text a
    /// source sent or a person typed, so it may contain the delimiter, and putting it at the
    /// end means nothing has to be escaped or rejected.
    ///
    /// No empty-label form. Clearing a merchant rule is removing its line from the Raw journal,
    /// which is a different act from clearing one row — and one that should be deliberate,
    /// because it puts every transaction from that shop back in the queue to be asked about.
    static func composeMerchantCategory(
        merchant: String,
        label: String,
        source: JournalInstruction.Source
    ) -> String {
        [
            merchantCategoryPrefix,
            label.trimmingCharacters(in: .whitespacesAndNewlines),
            source.rawValue,
            merchant.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: delimiter)
    }

    // MARK: - Reading

    static func parse(_ text: String) -> JournalInstruction? {
        // One split for the bank shape, one for the edit shape. The edit needs `maxSplits` so
        // the merchant stays in one piece and keeps any `|` of its own.
        let head = text
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard head.count == 2 else { return nil }

        switch head[0].lowercased() {
        case bankPrefix.lowercased():
            // Signed: an overdrawn account is a real balance.
            guard let minor = Money.signedMinorUnits(from: head[1]) else { return nil }
            return .setBankBalance(minor: minor)

        case cardPrefix.lowercased():
            // Signed the same way, and for a different reason: a card in credit is real too.
            guard let minor = Money.signedMinorUnits(from: head[1]) else { return nil }
            return .setCardBalance(minor: minor)

        case editPrefix.lowercased():
            return parseEdit(text)

        case categoryPrefix.lowercased():
            return parseCategory(text)

        case merchantCategoryPrefix.lowercased():
            return parseMerchantCategory(text)

        default:
            return nil
        }
    }

    private static func parseEdit(_ text: String) -> JournalInstruction? {
        let fields = text
            .split(separator: "|", maxSplits: 5, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // `fields[5]` is the merchant, which is required. Not `fields[4]`, which is the card
        // and is legitimately empty for a deposit — checking that one rejected every edit made
        // to a row without a card, including every deposit.
        guard fields.count == 6, !fields[5].isEmpty else { return nil }

        let cardSuffix = fields[4]
        guard cardSuffix.isEmpty || ManualEntryParser.isValidCardSuffix(cardSuffix) else {
            return nil
        }

        // Signed, like everything a person types: a refund is a negative charge.
        guard let amountMinor = Money.signedMinorUnits(from: fields[2]) else { return nil }

        // The same rule the manual line holds: an absent date is fine, an unreadable one is a
        // rejection. Treating a typo as "no date" would quietly redate the row to its arrival.
        var occurredAt: Date?
        if !fields[3].isEmpty {
            guard let noon = DayFormat.noon(fromDayText: fields[3]) else { return nil }
            occurredAt = noon
        }

        guard !fields[1].isEmpty else { return nil }

        return .edit(
            JournalInstruction.Edit(
                occurrenceKey: fields[1],
                amountMinor: amountMinor,
                occurredAt: occurredAt,
                cardSuffix: cardSuffix,
                merchant: fields[5]
            )
        )
    }

    /// `Category | <occurrenceKey> | <label> | <source>`, with `maxSplits: 3`.
    ///
    /// Four fields and no more. The occurrence key cannot contain the delimiter — it is a UUID
    /// and an index — so unlike the merchant-bearing lines there is nothing here that has to be
    /// allowed to hold a `|`. A fifth field is therefore not a future extension to tolerate but
    /// evidence the line is not the shape it claims, and it is refused.
    private static func parseCategory(_ text: String) -> JournalInstruction? {
        let fields = text
            .split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count == 4 else { return nil }
        guard let source = JournalInstruction.Source(rawValue: fields[3].lowercased()) else { return nil }

        // The key has to be shaped like one, or this line names nothing and would sit in the
        // journal forever being re-read on every drain for no reason.
        let key = fields[1]
        guard !key.isEmpty, key.contains("#") else { return nil }

        let label = fields[2]
        if label.isEmpty {
            // An explicit clear, and only a person can make one. The model has no route to this
            // line at all, so an `ai` clear would be a line nothing could have written — read as
            // unreadable rather than honoured, on the same principle as a rejected parse.
            guard source == .user else { return nil }
        } else {
            guard SpendingCategory.isWellFormed(label) else { return nil }
        }

        return .category(
            JournalInstruction.Category(
                occurrenceKey: key,
                label: label.isEmpty ? nil : label,
                source: source
            )
        )
    }

    /// `MerchantCategory | <label> | <source> | <merchant>`, with `maxSplits: 3` so the merchant
    /// stays in one piece and keeps any `|` of its own.
    private static func parseMerchantCategory(_ text: String) -> JournalInstruction? {
        let fields = text
            .split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count == 4 else { return nil }
        guard let source = JournalInstruction.Source(rawValue: fields[2].lowercased()) else { return nil }

        let label = fields[1]
        guard SpendingCategory.isWellFormed(label) else { return nil }

        // The merchant is required. A rule naming no merchant would match every row whose
        // normalised key happened to be empty, which is the one way a single line could
        // categorise the entire ledger at once.
        let merchant = fields[3]
        guard !merchant.isEmpty else { return nil }

        return .merchantCategory(
            JournalInstruction.MerchantCategory(merchant: merchant, label: label, source: source)
        )
    }

    /// Whether this line is an instruction at all, without caring which one.
    ///
    /// Used by the purge, which has to keep these forever for the same reason it keeps a
    /// charge forever: the state they establish is rebuilt from them.
    static func isInstruction(_ text: String) -> Bool { parse(text) != nil }

    /// Whether this text is *shaped* like a line the app wrote to itself, whether or not the
    /// current parser can read it.
    ///
    /// `isInstruction` answers "can I read this", and the two are not the same question — which
    /// matters because the only caller is the retention purge, and for it the difference is
    /// whether a line survives. A `Bank` or `Category` line written by a version whose format
    /// this one does not understand is *unreadable and irreplaceable at once*: it holds a
    /// decision the user made, and nothing else on disk records it. Judged on `isInstruction`
    /// alone it looks exactly like a merchant's receipt, ages out after a week, and takes the
    /// user's decision with it — silently, on a device where the user is the only person who
    /// could ever have noticed.
    ///
    /// Checking the leading token instead keeps it. The cost is that a *captured* body which
    /// happens to begin `Bank |` is kept forever rather than for a week — a real cost, and the
    /// cheap direction of it: a line kept too long is recoverable, and a line dropped is not.
    static func hasInstructionPrefix(_ text: String) -> Bool {
        let token = text
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        return prefixes.contains { $0.lowercased() == token }
    }
}
