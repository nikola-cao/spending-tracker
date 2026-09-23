//
//  FidelityAlertParserTests.swift
//  spending-trackerTests
//

import Foundation
import Testing
@testable import spending_tracker

struct FidelityAlertParserTests {

    /// The main corpus sweep. Each fixture fails independently, so a regression names itself.
    @Test("corpus", arguments: AlertCorpus.all)
    func corpus(_ fixture: AlertFixture) {
        let actual = FidelityAlertParser.parseAll(fixture.input)
        #expect(actual == fixture.expected, "fixture: \(fixture.name)")
    }

    /// The adversarial set, kept in its own test so a regression here is obviously distinct
    /// from a regression in the ordinary corpus.
    @Test("adversarial", arguments: AlertCorpus.adversarial)
    func adversarial(_ fixture: AlertFixture) {
        let actual = FidelityAlertParser.parseAll(fixture.input)
        #expect(actual == fixture.expected, "fixture: \(fixture.name)")
    }

    /// The pattern is kept as a string so a dialect problem surfaces here rather than as a
    /// silent no-match in production. `NSRegularExpression` is ICU-backed, and ICU is not
    /// quite Python's `re` — the prototype this was ported from was validated under Python.
    @Test func patternCompiles() {
        #expect(FidelityAlertParser.regex != nil)
    }

    /// The arithmetic must be overflow-free for ANY captured amount, not merely the
    /// bounded ones. This is the guard against a repeat of the trap that killed the process.
    @Test func amountArithmeticCannotOverflow() {
        let absurd = ["9" + String(repeating: "0", count: 40), "92233720368547759", "99999999999999999999"]
        for value in absurd {
            #expect(Money.minorUnits(from: value) == nil, "accepted \(value)")
        }
        #expect(Money.minorUnits(from: "1,000,000,000.00") == 100_000_000_000)
        #expect(Money.minorUnits(from: "10,000,000,000.00") == nil)
    }

    /// Normalisation is what makes a newline survivable, so pin it directly.
    @Test func normalisationFlattensNewlinesAndInvisibles() {
        #expect(FidelityAlertParser.normalize("a\nb") == "a b")
        #expect(FidelityAlertParser.normalize("a\r\nb") == "a b")
        #expect(FidelityAlertParser.normalize("a\u{200B}b") == "ab")
        #expect(FidelityAlertParser.normalize("a\u{FEFF}b") == "ab")
    }

    @Test(arguments: [
        ("2.50", 250),
        ("1,204.99", 120499),
        ("36", 3600),
        ("0.05", 5),
        ("0.99", 99),
        ("1.5", 150),
        ("1,000,000.00", 100_000_000),
    ])
    func minorUnitsFromValidAmounts(_ c: (String, Int)) {
        #expect(Money.minorUnits(from: c.0) == c.1)
    }

    @Test(arguments: ["", "abc", "1.234", "1.2.3", ".", "$"])
    func minorUnitsRejectsMalformed(_ input: String) {
        #expect(Money.minorUnits(from: input) == nil)
    }

    /// Why money is integer cents and never a binary float.
    ///
    /// `Int()` truncates, so a product that lands a hair *below* the integer silently loses
    /// a cent. `1.15 * 100` is 114.99999999999999, which becomes 114 — not 115. Note that
    /// not every value misbehaves (1204.99 * 100 happens to round cleanly to 120499), which
    /// is exactly what makes this class of bug dangerous: it is value-dependent, so it
    /// passes every test you happen to write and then drops a cent in production.
    @Test func integerCentsBeatDoubleForMoney() {
        #expect(Int(1.15 * 100) == 114)                                // a cent, silently lost
        #expect(Money.minorUnits(from: "1.15") == 115)   // exact, always
        #expect(Money.minorUnits(from: "1,204.99") == 120499)
    }

    /// `parseFirst` must agree with `parseAll` — the ledger will use one and the UI the other.
    @Test func parseFirstAgreesWithParseAll() {
        for fixture in AlertCorpus.all {
            #expect(FidelityAlertParser.parseFirst(fixture.input) == fixture.expected.first,
                    "fixture: \(fixture.name)")
        }
    }

    /// Guards the property that makes the journal replayable: parsing is a pure function of
    /// the raw text, so the same input always yields the same result.
    @Test func parsingIsPureAndRepeatable() {
        let input = AlertCorpus.realMessages[0].input
        let first = FidelityAlertParser.parseAll(input)
        for _ in 0..<50 {
            #expect(FidelityAlertParser.parseAll(input) == first)
        }
    }
}
