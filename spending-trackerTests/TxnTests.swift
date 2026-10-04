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
}
