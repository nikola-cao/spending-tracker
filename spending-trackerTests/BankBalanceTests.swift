//
//  BankBalanceTests.swift
//  spending-trackerTests
//
//  The one figure in the app a person types in, and the minus sign it allows that nothing
//  else here does.
//

import Foundation
import Testing
@testable import spending_tracker

struct BankBalanceTests {

    @Test(arguments: [
        ("0", 0),
        ("12.34", 1234),
        ("$12.34", 1234),
        ("36", 3600),
        ("1,204.99", 120_499),
        ("-40.00", -4000),
        ("-$40.00", -4000),
        ("-1,204.99", -120_499),
        ("  12.34  ", 1234),
    ])
    func acceptedForms(_ testCase: (text: String, minor: Int)) {
        #expect(Money.signedMinorUnits(from: testCase.text) == testCase.minor,
                "\(testCase.text)")
    }

    /// Everything `Money` refuses is still refused — an overdraft is a real balance, an
    /// ambiguous `"2,50"` is still not a number.
    @Test(arguments: [
        "", "   ", "-", "$", "-$", "--40.00", "$-40.00", "abc", "2,50", "1.2.3", "40.00-",
    ])
    func rejectedForms(_ text: String) {
        #expect(Money.signedMinorUnits(from: text) == nil, "accepted \(text)")
    }

    // MARK: - Round trip

    /// The sheet pre-fills from the stored value, so anything it can save has to be readable
    /// back. A negative is where this previously broke: `-4050` formatted by parts came out as
    /// `"-40.-50"`, which `minorUnits(from:)` then correctly refuses, leaving a balance that
    /// could be saved once and never edited again.
    @Test(arguments: [0, 5, 100, 1234, 120_499, -5, -100, -1234, -120_499])
    func everyAcceptedBalanceRoundTrips(_ minor: Int) {
        let text = Money.decimalString(fromMinor: minor)
        #expect(Money.signedMinorUnits(from: text) == minor, "\(minor) via \(text)")
    }
}
