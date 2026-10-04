//
//  JournalLineOutcome.swift
//  spending-tracker
//
//  What a raw journal line is, for the one screen that can destroy it.
//

import Foundation

/// What a line of the raw journal turned out to be, and therefore what deleting it takes away.
///
/// This exists for the confirmation the Raw journal asks before it destroys anything. The
/// journal is the one thing in this app with no undo, so "Delete?" on its own is not enough:
/// the user is entitled to know whether a transaction goes with the line, whether a figure they
/// set is about to be restated, and whether they are giving up the only copy of the text.
///
/// Classified by **re-parsing the line**, which is what the drain itself would do, rather than
/// by the record's `note` or its leading token. `note == "manual"` covers a pasted free-text
/// alert, a composed `Manual | …` line, a `Bank | …` line and an `Edit | …` line alike, so it
/// says nothing about what deleting that particular line would do.
nonisolated enum JournalLineOutcome: Equatable {

    /// Nothing but whitespace. The intent journals an empty invocation on purpose — "ran with
    /// empty input" has to stay distinguishable from "never ran".
    case empty

    /// A line the app wrote to itself: a balance the user set, or an edit naming a row.
    case instruction(JournalInstruction)

    /// A real movement of money. Every entry is a ledger entry.
    case movement(entries: [ParsedAlert])

    /// Text that resolved to no movement — a merchant's own confirmation, an OTP, a statement
    /// notice.
    case nothing
}

extension JournalRecord {
    /// What this line is. Cheap enough to call for a confirmation dialog, and never cached:
    /// a cached answer could disagree with the parser that is actually running.
    nonisolated var outcome: JournalLineOutcome {
        let body = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return .empty }

        // Instructions first, and never through `AlertParsers`: that registry answers "what did
        // this message mean", and a `Bank |` line arrived from no message at all.
        if let instruction = JournalInstructionParser.parse(body) {
            return .instruction(instruction)
        }

        let entries = AlertParsers.parseAll(body).filter(\.isLedgerEntry)
        return entries.isEmpty ? .nothing : .movement(entries: entries)
    }
}

extension JournalLineOutcome {

    /// The confirmation copy, given how many ledger rows the store actually holds for this
    /// line's invocation.
    ///
    /// `storedRows` comes from the ledger rather than from this classification, and the two are
    /// allowed to disagree — see `LedgerStore.rowsRecorded(by:)`. When they do, the store wins
    /// the sentence about rows, because the store is what is about to change.
    ///
    /// Built as an array and joined rather than as one chained expression: the README records
    /// that a long concatenation of interpolated ternaries blows the type checker's time
    /// budget, and this is exactly that shape of string.
    nonisolated func message(storedRows: Int) -> String {
        var parts: [String] = []

        switch self {
        case .empty:
            parts.append("This line is an empty invocation — the automation ran and handed over nothing.")
            parts.append("It is the only evidence that it ran at all.")
            if let note = storedRowsNote(storedRows) { parts.append(note) }

        case .instruction(let instruction):
            switch instruction {
            case .setBankBalance:
                parts.append("This line is a bank balance you set.")
                parts.append("Deleting it removes that assertion, and the Bank figure is restated "
                             + "from the balance and deposits the journal still holds.")
            case .edit:
                parts.append("This line is an edit to a row you already had.")
                parts.append("Deleting it undoes the change: the row goes back to what the line "
                             + "this one superseded said.")
            }

        case .movement(let entries):
            if storedRows > 0 {
                let noun = storedRows == 1 ? "transaction" : "transactions"
                parts.append("This line recorded \(storedRows) \(noun).")
                let pronoun = storedRows == 1 ? "that transaction" : "all \(storedRows)"
                parts.append("Deleting it removes \(pronoun) from the ledger, and the line itself.")
            } else {
                // Reads as a movement but nothing is stored under it — a line that arrived and
                // was never drained, or whose drain failed. Say what is actually true.
                parts.append("This line reads as a movement of money, but no transaction is stored for it.")
                parts.append("Deleting it removes the line, and nothing in the ledger changes.")
            }
            // `affectsBank`, not `isDeposit`: a payment moves the bank too, and it is the kind
            // most likely to be deleted by mistake — it looks like a large charge. Asking
            // "is this a deposit" would have left the one line whose deletion moves the Bank
            // figure as the one line whose confirmation stayed silent about it.
            if entries.contains(where: { $0.affectsBank }) {
                parts.append("It moved the bank, so the Bank figure changes with it.")
            }

        case .nothing:
            if let note = storedRowsNote(storedRows) {
                // The re-parse and the store disagree: a body an earlier parser recognised and
                // this one does not. Deletion is keyed on the invocation, never on this
                // classification, so the store wins the sentence about rows.
                parts.append("This line no longer reads as a transaction.")
                parts.append(note)
            } else {
                parts.append("No transaction was recorded from this line.")
                // The week is a recovery window, not a bin: a body that resolves to nothing is
                // re-parsed on every drain, so a charge that starts being recognised inside the
                // window becomes a row with no special handling. Deleting ends that early, and
                // it is the difference between "we cannot read this" and "this was never a
                // charge" — which nothing here can actually tell apart.
                parts.append("It is held for a week and re-read on every pass, so a charge that "
                             + "starts being recognised inside that window still gets picked up. "
                             + "Deleting it now gives up the rest of that window.")
            }
            parts.append("This is also the only copy of the text.")
        }

        parts.append("This cannot be undone.")
        return parts.joined(separator: " ")
    }

    /// The sentence for rows the store holds that the line's own text no longer accounts for.
    ///
    /// Nil when there are none, so the caller can keep the ordinary wording. This is what stops
    /// a confirmation saying "nothing in the ledger changes" about a body the current parser
    /// cannot read but an earlier one recorded — the row is real, and the delete takes it.
    nonisolated private func storedRowsNote(_ storedRows: Int) -> String? {
        guard storedRows > 0 else { return nil }
        let noun = storedRows == 1 ? "a transaction" : "\(storedRows) transactions"
        return "The ledger still holds \(noun) recorded from this line, and deleting it removes that too."
    }
}
