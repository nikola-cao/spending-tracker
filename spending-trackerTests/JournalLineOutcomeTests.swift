//
//  JournalLineOutcomeTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

/// What the Raw journal screen promises before it destroys a line.
///
/// The journal is the one thing in this app with no undo, so the confirmation copy is not
/// decoration — it is the only thing standing between a tap and an unrecoverable loss. These
/// tests pin the claims it makes, because a copy that overstates or understates the damage is
/// worse than none: it is the reason the user decided to go ahead.
struct JournalLineOutcomeTests {

    private let trailer = " Msg&Data rates may apply. Reply STOP to cancel."

    private var chargeBody: String {
        "Fidelity\u{00AE} Credit Card: Your card ending in 7224 was charged $2.50 at BREEZE*00HS5MV."
            + trailer
    }

    /// A merchant's own booking confirmation, captured by the Email automation alongside the
    /// Amex alert for the same purchase. Resolves to no ledger entry.
    private var receipt: String {
        """
        You're all set for Gatlinburg
        Charm of Gatlinburg Mountain Retreat condo
        Total (USD)
        $515.66
        Payment
        Amex 1008
        September 22, 2026, 8:39:03 PM EDT
        """
    }

    private func record(_ body: String) -> JournalRecord {
        .diagnostic(runID: UUID(), phase: JournalRecord.capturePhase, raw: body, note: "")
    }

    private func isMovement(_ outcome: JournalLineOutcome) -> Bool {
        if case .movement = outcome { return true }
        return false
    }

    // MARK: - Classification

    @Test func aChargeLineIsAMovement() {
        #expect(isMovement(record(chargeBody).outcome))
    }

    /// The headline case: the line the feed could never delete, because there is no row to
    /// swipe. It must classify as something the copy can be honest about.
    @Test func aReceiptIsNothing() {
        #expect(record(receipt).outcome == .nothing)
    }

    /// The intent journals an empty invocation on purpose, so that "ran with empty input" stays
    /// distinguishable from "never ran". Deleting it destroys that distinction, which is the
    /// only thing the line exists for.
    @Test func anEmptyBodyIsItsOwnCase() {
        #expect(record("   \n  ").outcome == .empty)
    }

    /// Instructions are classified before alerts, and never through `AlertParsers` — a `Bank |`
    /// line arrived from no message, and the two readers answer different questions.
    @Test func aBalanceLineIsAnInstruction() {
        #expect(record("Bank | 1234.56").outcome == .instruction(.setBankBalance(minor: 123_456)))
    }

    /// A card balance is an instruction too, and a separate one — the two lines are told apart
    /// by their leading word, so a `Card` line must not classify as a bank assertion. The
    /// confirmation the swipe shows names which figure moves, and naming the wrong one is a
    /// promise about the wrong number.
    @Test func aCardBalanceLineIsItsOwnInstruction() {
        #expect(record("Card | 240.00").outcome == .instruction(.setCardBalance(minor: 24_000)))
    }

    @Test func anEditLineIsAnEditInstruction() {
        let line = "Edit | \(UUID().uuidString)#0 | 4.00 |  | 7224 | BREEZE COFFEE"
        guard case .instruction(.edit(let edit)) = record(line).outcome else {
            Issue.record("an Edit line must classify as an edit instruction")
            return
        }
        #expect(edit.merchant == "BREEZE COFFEE")
        #expect(edit.amountMinor == 400)
    }

    /// Classification is by re-parsing, not by the `note`. A hand-typed alert, a composed
    /// `Manual` line and a `Bank` line all carry `note == "manual"`, and they mean three
    /// different things about what deleting the line would do.
    @Test func theNoteDoesNotDecideTheOutcome() {
        #expect(isMovement(record(chargeBody).outcome), "a pasted alert is a movement, not 'manual'")
        let deposit = ManualEntryParser.compose(
            kind: .deposit, merchant: "ZELLE", amount: "25.00", date: nil, cardSuffix: "")
        #expect(isMovement(record(deposit).outcome))
        #expect(record("Bank | 10.00").outcome == .instruction(.setBankBalance(minor: 1_000)))
    }

    // MARK: - What the copy promises

    /// The promise the retention window exists for. A body that resolves to no charge is
    /// re-parsed on every drain, so a charge that starts being recognised inside the week is
    /// picked up normally. Deleting the line ends that early — which is a real loss, and the
    /// copy has to own it rather than calling the line junk.
    @Test func theNothingMessageOwnsTheRecoveryWindowItGivesUp() {
        let message = JournalLineOutcome.nothing.message(storedRows: 0)
        #expect(message.contains("week"))
        #expect(message.contains("only copy"))
    }

    /// And it may not assert that the line was never a charge. Nothing in the app can tell a
    /// real charge in a format the parser does not know from an OTP, so the honest sentence is
    /// about what was recorded, not about what the text was.
    @Test func theNothingMessageSaysWhatWasRecordedNotWhatTheTextWas() {
        let message = JournalLineOutcome.nothing.message(storedRows: 0)
        #expect(message.contains("No transaction was recorded from this line"))
    }

    /// The re-parse and the store are allowed to disagree, and here they do: a body an earlier
    /// parser recognised and this one cannot read still owns its row. Deletion is keyed on the
    /// invocation rather than on the classification, so the copy has to follow the store — a
    /// promise that nothing in the ledger changes would be false, and it is the promise the
    /// user decides on.
    @Test func theNothingMessageAdmitsWhenTheStoreStillHoldsARow() {
        let message = JournalLineOutcome.nothing.message(storedRows: 1)
        #expect(message.contains("no longer reads as a transaction"))
        #expect(message.contains("still holds a transaction"))
        #expect(!message.contains("No transaction was recorded"))

        let two = JournalLineOutcome.nothing.message(storedRows: 2)
        #expect(two.contains("still holds 2 transactions"))
    }

    /// The row count comes from the store, so the sentence about rows has to follow it. It is
    /// also the case that catches a re-parse disagreeing with what is stored.
    @Test func theMovementMessageCountsWhatIsActuallyThere() {
        let outcome = JournalLineOutcome.movement(entries: [])
        #expect(outcome.message(storedRows: 0).contains("nothing in the ledger changes"))
        #expect(outcome.message(storedRows: 1).contains("recorded 1 transaction"))
        #expect(outcome.message(storedRows: 2).contains("recorded 2 transactions"))
    }

    /// A deposit moves the Bank figure, so deleting its line moves it back. A copy that only
    /// counted ledger rows would leave the user to discover that for themselves.
    @Test func theMovementMessageWarnsWhenTheBankWillMove() {
        let deposit = ManualEntryParser.compose(
            kind: .deposit, merchant: "ZELLE", amount: "25.00", date: nil, cardSuffix: "")
        guard case .movement(let entries) = record(deposit).outcome else {
            Issue.record("a composed Manual deposit must classify as a movement")
            return
        }
        let allDeposits = entries.allSatisfy(\.isDeposit)
        #expect(allDeposits)
        #expect(JournalLineOutcome.movement(entries: entries)
            .message(storedRows: 1).contains("Bank figure changes"))
    }

    /// A payment moves the bank exactly as a deposit does — it is the movement that comes off
    /// both figures. It is also the one most likely to be deleted by mistake, because it reads
    /// as a very large charge, so it must not be the line whose confirmation stays silent about
    /// the Bank figure. Asking `isDeposit` here would have done exactly that.
    @Test func aPaymentWarnsAboutTheBankToo() {
        let payment = ManualEntryParser.compose(
            kind: .payment, merchant: "AMEX PAYMENT", amount: "-825.77", date: nil, cardSuffix: "")
        guard case .movement(let entries) = record(payment).outcome else {
            Issue.record("a composed Manual payment must classify as a movement")
            return
        }
        let allAffectTheBank = entries.allSatisfy(\.affectsBank)
        #expect(allAffectTheBank)
        #expect(JournalLineOutcome.movement(entries: entries)
            .message(storedRows: 1).contains("Bank figure changes"))
    }

    /// The ordinary case, and the one the copy was silent about until the card balance existed:
    /// a captured charge.
    ///
    /// Nothing about the row suggests a figure depends on it — no money moved anywhere when it
    /// landed, it is only owed on a card. But the Balance figure is folded from exactly these
    /// rows, so deleting one restates it. A confirmation that said nothing would hide a figure
    /// moving behind the line that reads as pure bookkeeping.
    @Test func aChargeWarnsWhenTheBalanceWillMove() {
        guard case .movement(let entries) = record(chargeBody).outcome else {
            Issue.record("a captured charge must classify as a movement")
            return
        }
        let allAffectTheCard = entries.allSatisfy(\.affectsCard)
        let anyAffectTheBank = entries.contains(where: \.affectsBank)
        #expect(allAffectTheCard)
        #expect(!anyAffectTheBank, "a charge never moves the bank")
        #expect(JournalLineOutcome.movement(entries: entries)
            .message(storedRows: 1).contains("Balance figure changes"))
    }

    /// A payment is the one movement that moves both figures, so it gets both sentences. Naming
    /// one and not the other would leave the second to be discovered.
    @Test func aPaymentWarnsAboutBothFigures() {
        let payment = ManualEntryParser.compose(
            kind: .payment, merchant: "AMEX PAYMENT", amount: "-825.77", date: nil, cardSuffix: "")
        guard case .movement(let entries) = record(payment).outcome else {
            Issue.record("a composed Manual payment must classify as a movement")
            return
        }
        let message = JournalLineOutcome.movement(entries: entries).message(storedRows: 1)
        #expect(message.contains("Bank figure changes"))
        #expect(message.contains("Balance figure changes"))
    }

    /// And a deposit names the bank and only the bank. The two sentences are separate for
    /// exactly this: one copy that named both for every movement would be wrong about every
    /// Zelle, and a deposit never touches a card.
    @Test func aDepositWarnsAboutTheBankAndNotTheBalance() {
        let deposit = ManualEntryParser.compose(
            kind: .deposit, merchant: "ZELLE", amount: "25.00", date: nil, cardSuffix: "")
        guard case .movement(let entries) = record(deposit).outcome else {
            Issue.record("a composed Manual deposit must classify as a movement")
            return
        }
        let message = JournalLineOutcome.movement(entries: entries).message(storedRows: 1)
        #expect(message.contains("Bank figure changes"))
        #expect(!message.contains("Balance figure changes"))
    }

    /// An instruction is not a row, so a copy that counted only rows would promise "nothing
    /// changes" while the Bank figure moved or a row reverted. Each instruction names its own
    /// visible consequence instead.
    @Test func theInstructionMessageExplainsTheVisibleConsequence() {
        let bank = JournalLineOutcome.instruction(.setBankBalance(minor: 1_000))
        #expect(bank.message(storedRows: 0).contains("Bank figure is restated"))

        // And it names the *Balance* figure, not the Bank one. "Balance" is now the card figure
        // on the summary row, so a card line whose copy said "Bank" would point at a number
        // that was never going to move.
        let card = JournalLineOutcome.instruction(.setCardBalance(minor: 24_000))
        #expect(card.message(storedRows: 0).contains("Balance figure is restated"))
        #expect(!card.message(storedRows: 0).contains("Bank figure"))

        let edit = JournalInstruction.Edit(
            occurrenceKey: "x#0", amountMinor: 400, occurredAt: nil, cardSuffix: "", merchant: "M")
        #expect(JournalLineOutcome.instruction(.edit(edit))
            .message(storedRows: 0).contains("goes back to what the line"))
    }

    /// Every one of them ends by saying the same thing, because it is true of all of them: the
    /// journal has no undo, and the text is the only copy.
    @Test func everyMessageSaysItCannotBeUndone() {
        let all: [JournalLineOutcome] = [
            .empty,
            .instruction(.setBankBalance(minor: 1)),
            .instruction(.setCardBalance(minor: 1)),
            .movement(entries: []),
            .nothing,
        ]
        for outcome in all {
            #expect(outcome.message(storedRows: 0).contains("cannot be undone"))
        }
    }
}
