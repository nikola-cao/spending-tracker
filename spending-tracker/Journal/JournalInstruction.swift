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
}

/// Reads and writes those lines. Same arrangement as every other source: one owner for the
/// format, so the writer and the reader cannot drift apart.
nonisolated enum JournalInstructionParser {

    /// The leading token for a bank balance. Reads plainly in the raw journal, where a person
    /// may be looking straight at it.
    static let bankPrefix = "Bank"

    private static let delimiter = " | "

    // MARK: - Writing

    /// `Bank | 1234.56`
    ///
    /// The canonical decimal rather than what was typed, for the same reason the other
    /// composers use it: the line has to be re-readable however the amount was written.
    static func composeBankBalance(_ minor: Int) -> String {
        [bankPrefix, Money.decimalString(fromMinor: minor)].joined(separator: delimiter)
    }

    // MARK: - Reading

    static func parse(_ text: String) -> JournalInstruction? {
        let fields = text
            .split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        guard fields.count == 2, fields[0].lowercased() == bankPrefix.lowercased() else {
            return nil
        }
        // Signed: an overdrawn account is a real balance.
        guard let minor = Money.signedMinorUnits(from: fields[1]) else { return nil }
        return .setBankBalance(minor: minor)
    }

    /// Whether this line is an instruction at all, without caring which one.
    ///
    /// Used by the purge, which has to keep these forever for the same reason it keeps a
    /// charge forever: the state they establish is rebuilt from them.
    static func isInstruction(_ text: String) -> Bool { parse(text) != nil }
}
