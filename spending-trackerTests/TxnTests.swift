//
//  TxnTests.swift
//  spending-trackerTests
//
//  What a row says about itself, independent of any view.
//

import Foundation
import Testing
@testable import spending_tracker

struct TxnTests {

    private func row(
        _ minor: Int,
        kind: ParsedAlert.Kind = .charge,
        merchant: String = "ROW"
    ) -> Txn {
        Txn(
            amountMinor: minor,
            currencyCode: "USD",
            cardSuffix: "",
            merchant: merchant,
            receivedAt: Date(timeIntervalSince1970: 1_780_000_000),
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000),
            occurredAtIsFromMessage: false,
            parserVersion: 1,
            kind: kind
        )
    }

    // MARK: - Which rows are money coming in

    /// The four cases, which is the whole rule: the sign decides, not the kind.
    @Test func theSignDecidesWhetherMoneyCameIn() {
        #expect(row(2_500, kind: .deposit).isMoneyIn, "a deposit is money arriving")
        #expect(row(-1_200, kind: .charge).isMoneyIn, "a refund is money coming back")
        #expect(!row(2_500, kind: .charge).isMoneyIn, "a charge is money going out")
        #expect(!row(-4_000, kind: .deposit).isMoneyIn,
                "a negative deposit is money leaving the bank, whatever it is called")
    }

    /// A zero deposit is not money arriving. It is not much of anything, but colouring it as
    /// good news would be a claim the row cannot support.
    @Test func aZeroAmountIsNotMoneyIn() {
        #expect(!row(0, kind: .deposit).isMoneyIn)
        #expect(!row(0, kind: .charge).isMoneyIn)
    }

    /// A payment is never money in, however it is signed.
    ///
    /// This is the trap the negative storage sets: a payment is stored as its effect, so its
    /// amount is negative — and the rule that makes a refund green would have made every
    /// payment green too.
    @Test func aPaymentIsNeverMoneyIn() {
        #expect(!row(-82_577, kind: .payment).isMoneyIn)
        #expect(!row(82_577, kind: .payment).isMoneyIn)
    }

    @Test func aPaymentIsItsOwnKind() {
        #expect(row(-100, kind: .payment).isPayment)
        #expect(!row(-100, kind: .payment).isDeposit)
        #expect(!row(-100, kind: .payment).isMoneyIn)
        #expect(!row(100, kind: .charge).isPayment)
    }

    /// The kind is stored as the raw string the journal writes, so a row read back from disk
    /// has to answer the same way one just built in memory does.
    @Test func theKindSurvivesBeingStoredAsItsRawValue() {
        #expect(row(100, kind: .deposit).isDeposit)
        #expect(!row(100, kind: .charge).isDeposit)
        #expect(row(100, kind: .deposit).kindRaw == "deposit")
        #expect(row(100, kind: .charge).kindRaw == "charge")
    }

    // MARK: - What the month cost

    /// The arithmetic behind the "This Month's Spending" figure, which until now had no test at
    /// all: it lived as a private computed property on a view, and a claim that can only be
    /// checked by launching the app is a claim nothing checks.
    ///
    /// Three rows, one of each kind that counts — and the third is the one that catches a sign
    /// error rather than a filter error. A Venmo you sent is stored as a *negative* deposit, so
    /// summing raw signs would make $200 leaving the bank reduce the month's spending by $200.
    @Test func theMonthTotalIsWhatLeft() {
        #expect(Txn.spendingTotal([row(1_000)]) == 1_000, "a charge is what the month cost")
        #expect(Txn.spendingTotal([row(-250)]) == -250, "a refund is a negative charge")
        #expect(Txn.spendingTotal([row(-20_000, kind: .deposit)]) == 20_000,
                "money sent by Venmo is a cost, not a credit")
    }

    /// Money arriving is not a negative cost. Folding a Zelle in would make a heavy month look
    /// cheap because someone paid you back for rent.
    @Test func moneyArrivingIsNotASaving() {
        #expect(Txn.spendingTotal([row(30_000, kind: .deposit)]) == 0)
    }

    /// A payment is the whole difference between this figure and the card balance, and the
    /// reason the two are not the same number. It settles spending that belongs to an earlier
    /// month — most of a statement was spent in the month before it — so letting it come off
    /// here would make a heavy month read as light because the previous bill was paid in it.
    @Test func aPaymentDoesNotComeOffTheMonth() {
        #expect(Txn.spendingTotal([row(-82_577, kind: .payment)]) == 0)
    }

    /// All five in one month: 40.00 charged, a 4.00 refund, 20.00 sent by Venmo, 300.00
    /// received, and the card paid off. What the month cost is 40 − 4 + 20.
    @Test func aRealisticMonthAddsUp() {
        let month = [
            row(4_000, merchant: "BREEZE COFFEE"),
            row(-400, merchant: "BREEZE COFFEE"),
            row(-2_000, kind: .deposit, merchant: "VENMO RENT"),
            row(30_000, kind: .deposit, merchant: "ZELLE FROM SAM"),
            row(-82_577, kind: .payment, merchant: "AMEX PAYMENT"),
        ]
        #expect(Txn.spendingTotal(month) == 5_600)
    }

    /// Nothing carried in from another month, because the function sums the rows it is handed
    /// and nothing else. That is what makes this the one figure on the screen that is the month
    /// alone — the rollover lives in the balances, not here.
    @Test func anEmptyMonthCostsNothing() {
        #expect(Txn.spendingTotal([]) == 0)
    }
}
