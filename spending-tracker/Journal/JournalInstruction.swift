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

    struct Edit: Equatable {
        let occurrenceKey: String
        let amountMinor: Int

        /// The whole date, or nil to clear it. Never a partial change: the form has one date
        /// field, and "the date is now this" is the only thing it can mean.
        let occurredAt: Date?

        let cardSuffix: String
        let merchant: String
    }
}

/// Reads and writes those lines. Same arrangement as every other source: one owner for the
/// format, so the writer and the reader cannot drift apart.
nonisolated enum JournalInstructionParser {

    /// The leading tokens. Each reads plainly in the raw journal, where a person may be looking
    /// straight at it.
    static let bankPrefix = "Bank"
    static let editPrefix = "Edit"

    private static let delimiter = " | "

    // MARK: - Writing

    /// `Bank | 1234.56`
    ///
    /// The canonical decimal rather than what was typed, for the same reason the other
    /// composers use it: the line has to be re-readable however the amount was written.
    static func composeBankBalance(_ minor: Int) -> String {
        [bankPrefix, Money.decimalString(fromMinor: minor)].joined(separator: delimiter)
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

        case editPrefix.lowercased():
            return parseEdit(text)

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

    /// Whether this line is an instruction at all, without caring which one.
    ///
    /// Used by the purge, which has to keep these forever for the same reason it keeps a
    /// charge forever: the state they establish is rebuilt from them.
    static func isInstruction(_ text: String) -> Bool { parse(text) != nil }
}
