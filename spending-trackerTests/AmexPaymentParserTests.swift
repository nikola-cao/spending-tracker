//
//  AmexPaymentParserTests.swift
//  spending-trackerTests
//
//  The real payment confirmation, as the automation hands it over: already-flattened text, not
//  markup, with the line breaks the Shortcut produced.
//

import Foundation
import Testing
@testable import spending_tracker

struct AmexPaymentParserTests {

    /// Verbatim from a real capture.
    static let realPayment = """
        Thanks for your payment received on Sep 30, 2026

        NIKOLA CAO
        Account Ending: 21006

        Thank you for your payment

        We received your payment.
        You're all set. You can view your updated balances online.

        Don't see the deduction in your bank account? The withdrawal date will vary depending on your bank. Please check with your bank if you have any questions.
        Payment amount:
        $1,044.97
        Processed on:
        Sep 30, 2026
        Helpful Links

        About your online security

        Manage your alerts

        View your account online

        Privacy statement
        Contact us
        Update your email address
        Stop receiving this alert
        Your account information is included above to help you recognize this as a customer care e-mail from American Express.
        """

    /// The Amex purchase alert, which arrives from the same sender with the same account line
    /// and a dollar figure of its own. It must never be read as a payment.
    static let largePurchaseAlert = """
        See the details about this purchase
        NIKOLA CAO
        Account Ending: 21006
        There was a large purchase on your Card
        Dear NIKOLA CAO,
        As you requested, we're letting you know that this purchase was more than $1.00.
        You can change the dollar amount of these large purchase notifications online.
        AIRBNB US SHORT TERM STAY
        $515.66*
        Tue, Sep 22, 2026
        *The amount above may not reflect the final amount
        """

    // MARK: - The real thing

    @Test func theRealPaymentReadsBackCorrectly() throws {
        let alert = try #require(AmexPaymentParser.parseFirst(Self.realPayment))

        #expect(alert.isPayment)
        #expect(!alert.isDeposit)
        #expect(!alert.isCharge)
        #expect(alert.merchant == "Amex payment")
        #expect(alert.cardSuffix == "21006")
        #expect(alert.currencyCode == "USD")
    }

    /// Stored as its effect. The figure Amex prints is what was paid; what the ledger needs is
    /// what it took away, and that is what makes the row come off both summaries by summing.
    @Test func theAmountIsStoredNegated() throws {
        let alert = try #require(AmexPaymentParser.parseFirst(Self.realPayment))
        #expect(alert.amountMinor == -104_497, "the email says $1,044.97")
    }

    @Test func theDateIsTheProcessedDate() throws {
        let alert = try #require(AmexPaymentParser.parseFirst(Self.realPayment))
        let occurredAt = try #require(alert.occurredAt)

        let calendar = Calendar.current
        #expect(calendar.component(.year, from: occurredAt) == 2026)
        #expect(calendar.component(.month, from: occurredAt) == 9)
        #expect(calendar.component(.day, from: occurredAt) == 30)
        #expect(calendar.component(.hour, from: occurredAt) == 12, "noon, as a date with no time")
    }

    /// The email opens with a date of its own — `received on Sep 30, 2026` — which is why the
    /// figure and the date are both read from under their labels instead. Here the two differ,
    /// and the `Processed on:` one has to win.
    @Test func theOpeningSentenceDateIsNotMistakenForTheProcessedDate() throws {
        let body = Self.realPayment
            .replacingOccurrences(of: "received on Sep 30, 2026", with: "received on Sep 28, 2026")

        let alert = try #require(AmexPaymentParser.parseFirst(body))
        let occurredAt = try #require(alert.occurredAt)
        #expect(Calendar.current.component(.day, from: occurredAt) == 30)
    }

    // MARK: - Refusing rather than reaching for a number

    /// The purchase alert carries an amount, an account line and the same sender. It is not a
    /// payment, and the only thing that says so is the envelope.
    @Test func aPurchaseAlertIsNotReadAsAPayment() {
        #expect(AmexPaymentParser.parseAll(Self.largePurchaseAlert).isEmpty)
        // And through the registry it is still claimed by its own parser.
        let routed = AlertParsers.parseFirst(Self.largePurchaseAlert)
        #expect(routed?.isCharge == true)
        #expect(routed?.isPayment == false)
    }

    @Test func theRegistryRoutesAPaymentToThePaymentParser() throws {
        let alert = try #require(AlertParsers.parseFirst(Self.realPayment))
        #expect(alert.isPayment)
        #expect(alert.parserVersion == AmexPaymentParser.version)
    }

    /// The amount label is required as well as the sentence, so a body that mentions receiving
    /// a payment but never states one is refused rather than guessed at.
    @Test func aBodyWithNoAmountLabelIsRefused() {
        let body = Self.realPayment.replacingOccurrences(of: "Payment amount:", with: "Amount due:")
        #expect(AmexPaymentParser.parseAll(body).isEmpty)
    }

    /// And the sentence is required as well as the label, so a bare field cannot claim a body.
    @Test func aBodyWithNoEnvelopeIsRefused() {
        let body = Self.realPayment
            .replacingOccurrences(of: "We received your payment.", with: "Your statement is ready.")
        #expect(AmexPaymentParser.parseAll(body).isEmpty)
    }

    /// A figure in the prose is not a figure. The paragraph above the label talks about a bank
    /// account, and the boilerplate further down cites a phone number.
    @Test func onlyAWholeLineCountsAsTheAmount() {
        let body = Self.realPayment
            .replacingOccurrences(of: "$1,044.97", with: "your bank for $99.99 or so")
        #expect(AmexPaymentParser.parseAll(body).isEmpty)
    }

    @Test func theOtherSourcesAreNotClaimed() {
        let venmo = "From: Venmo < venmo@venmo.com >\nParick paid you\n$\n28\n00\nSee transaction\n"
            + "Money credited to your Venmo account.\nDate\nOct 02, 2026"
        #expect(AmexPaymentParser.parseAll(venmo).isEmpty)

        let manual = "Manual | payment | -825.77 | 2026-10-03 |  | AMEX PAYMENT"
        #expect(AmexPaymentParser.parseAll(manual).isEmpty)
    }
}
