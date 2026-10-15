//
//  AlertParsersTests.swift
//  spending-trackerTests
//
//  The registry's own invariant: the version it stamps on everything it parses.
//

import Foundation
import Testing
@testable import spending_tracker

struct AlertParsersTests {

    /// `AlertParsers.version` packs every parser's version into one number, one decimal digit
    /// each. This asserts that packing rather than restating it.
    ///
    /// It is worth a test because the failure is silent. A parser whose version reaches ten does
    /// not collide loudly — it carries into its neighbour's digit, so two parsers stamp the same
    /// composite on rows parsed by different tables. That number is the only thing that makes an
    /// older row identifiable and history re-derivable after a fix, so a collision costs exactly
    /// the property the field exists for, and nothing else would notice.
    @Test func everyParserOwnsOneDecimalDigitAndTheDigitsAddUp() {
        let parsers: [(name: String, version: Int)] = [
            ("FidelityAlertParser", FidelityAlertParser.version),
            ("FidelityPaymentParser", FidelityPaymentParser.version),
            ("AmexAlertParser", AmexAlertParser.version),
            ("AmexPaymentParser", AmexPaymentParser.version),
            ("VenmoAlertParser", VenmoAlertParser.version),
            ("ManualEntryParser", ManualEntryParser.version),
        ]

        for parser in parsers {
            #expect((1...9).contains(parser.version),
                    "\(parser.name).version must be one digit, was \(parser.version)")
        }

        // Taken apart digit by digit, the composite has to return the versions above in order.
        // A parser added without a slot of its own breaks this, because its version carries into
        // a digit that already belongs to someone else.
        let composite = AlertParsers.version
        #expect(composite / 100_000 % 10 == FidelityAlertParser.version)
        #expect(composite / 10_000 % 10 == FidelityPaymentParser.version)
        #expect(composite / 1_000 % 10 == AmexAlertParser.version)
        #expect(composite / 100 % 10 == AmexPaymentParser.version)
        #expect(composite / 10 % 10 == VenmoAlertParser.version)
        #expect(composite % 10 == ManualEntryParser.version)
    }

    /// The registry keeps the **first** parser that recognises anything, so its order is a
    /// precedence, and it is the only thing deciding what a body carrying more than one alert
    /// records. Charges come before payments because a purchase is the ledger's primary record:
    /// losing one takes money out of the month as well as off the card, where losing a payment
    /// leaves a balance that is merely too high.
    ///
    /// This body is the case that makes the order visible — an Amex purchase alert and a
    /// Fidelity payment text in one entry — and it is only reachable by pasting two messages
    /// together, since each automation hands over one body. It is asserted rather than argued
    /// because the reason is invisible in the dispatch.
    @Test func aChargeOutranksAPaymentWhenOneBodyCarriesBoth() {
        let both = AmexPaymentParserTests.largePurchaseAlert + " "
            + FidelityPaymentParserTests.realPayment

        // Each could claim this body on its own, so the single result below is the order's doing
        // and not either pattern's.
        #expect(!FidelityPaymentParser.parseAll(both).isEmpty)
        #expect(!AmexAlertParser.parseAll(both).isEmpty)

        let recorded = AlertParsers.parseAll(both)
        #expect(recorded.count == 1)
        #expect(recorded.first?.isCharge == true)
        #expect(recorded.first?.merchant == "AIRBNB US SHORT TERM STAY")
    }
}
