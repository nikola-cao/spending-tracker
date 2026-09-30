//
//  FeedOrderTests.swift
//  spending-trackerTests
//
//  The feed's order. Small, but it is the thing the user reads the list for, and every rule
//  in it is the kind that fails silently — a wrong order still looks like a plausible list.
//

import Foundation
import Testing
@testable import spending_tracker

struct FeedOrderTests {

    // MARK: - Fixtures

    /// A charge that carries no date of its own — the Fidelity SMS shape, where `occurredAt`
    /// falls back to the arrival.
    private func charge(_ merchant: String, arrived: Date) -> Txn {
        Txn(
            amountMinor: 100,
            currencyCode: "USD",
            cardSuffix: "7224",
            merchant: merchant,
            receivedAt: arrived,
            occurredAt: arrived,
            occurredAtIsFromMessage: false,
            parserVersion: 1
        )
    }

    /// A charge whose source printed a date and no time — the Amex shape. `occurredAt` is the
    /// purchase day, which both parsers pin to noon.
    private func datedCharge(_ merchant: String, purchasedOn day: Date, arrived: Date) -> Txn {
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        return Txn(
            amountMinor: 100,
            currencyCode: "USD",
            cardSuffix: "21008",
            merchant: merchant,
            receivedAt: arrived,
            occurredAt: noon,
            occurredAtIsFromMessage: true,
            parserVersion: 1
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    private func order(_ txns: [Txn]) -> [String] {
        Txn.feedOrder(txns).map(\.merchant)
    }

    // MARK: - The day decides, not the arrival

    /// The point of the change: an Amex email Apple Mail delivered a day late still belongs to
    /// the day it was spent, so it sorts below a charge made the next day — even though it
    /// arrived *after* it.
    @Test func aChargeSortsByItsPurchaseDayEvenWhenItArrivedLater() {
        let amex = datedCharge(
            "AMEX PURCHASE", purchasedOn: date(2026, 9, 20), arrived: date(2026, 9, 22, 9, 0))
        let sms = charge("SMS PURCHASE", arrived: date(2026, 9, 21, 14, 0))

        #expect(order([amex, sms]) == ["SMS PURCHASE", "AMEX PURCHASE"])
        // And the reverse input gives the same answer, so this is the order and not an
        // accident of the array it was handed.
        #expect(order([sms, amex]) == ["SMS PURCHASE", "AMEX PURCHASE"])
    }

    @Test func daysAreNewestFirst() {
        let oldest = datedCharge("A", purchasedOn: date(2026, 9, 1), arrived: date(2026, 9, 1))
        let newest = datedCharge("C", purchasedOn: date(2026, 9, 3), arrived: date(2026, 9, 3))
        let middle = datedCharge("B", purchasedOn: date(2026, 9, 2), arrived: date(2026, 9, 2))

        #expect(order([oldest, middle, newest]) == ["C", "B", "A"])
    }

    // MARK: - Within a day, arrival

    /// Two Amex charges on one day carry the same parsed date, so only arrival can order them.
    @Test func sameDayDateOnlyChargesKeepArrivalOrder() {
        let first = datedCharge("FIRST", purchasedOn: date(2026, 9, 20), arrived: date(2026, 9, 20, 8, 0))
        let second = datedCharge("SECOND", purchasedOn: date(2026, 9, 20), arrived: date(2026, 9, 20, 11, 0))

        #expect(order([first, second]) == ["SECOND", "FIRST"])
    }

    /// The ambiguous case: one charge on the day has a time and the other does not. Comparing
    /// the two instants would put the date-only charge first here (its fabricated noon beats
    /// the other's 09:00), which nothing in either message actually claims. Arrival decides.
    @Test func oneTimedAndOneDateOnlyChargeOnTheSameDayGoByArrival() {
        let dateOnly = datedCharge(
            "NO TIME", purchasedOn: date(2026, 9, 20), arrived: date(2026, 9, 20, 8, 0))
        let timed = charge("HAS TIME", arrived: date(2026, 9, 20, 9, 0))

        // Arrival says HAS TIME is newer, and it must win despite NO TIME's later instant.
        #expect(order([dateOnly, timed]) == ["HAS TIME", "NO TIME"])
    }

    @Test func aWholeDayOfTimedChargesIsArrivalOrderedToo() {
        let early = charge("EARLY", arrived: date(2026, 9, 20, 9, 0))
        let late = charge("LATE", arrived: date(2026, 9, 20, 17, 30))

        #expect(order([early, late]) == ["LATE", "EARLY"])
    }

    // MARK: - Mixed

    /// Days are still decided by the purchase day even when the day below them is ordered by
    /// arrival — the two rules have to compose rather than one swallowing the other.
    @Test func theDayRuleAndTheArrivalRuleCompose() {
        let olderDay = datedCharge("OLD DAY", purchasedOn: date(2026, 9, 19), arrived: date(2026, 9, 21, 7, 0))
        let newerFirst = charge("NEWER FIRST", arrived: date(2026, 9, 20, 8, 0))
        let newerSecond = charge("NEWER SECOND", arrived: date(2026, 9, 20, 12, 0))

        #expect(order([olderDay, newerFirst, newerSecond]) == ["NEWER SECOND", "NEWER FIRST", "OLD DAY"])
    }

    // MARK: - The month filter
    //
    // The list shows one month at a time. A filter, never a deletion — so the property to pin
    // down is which rows it picks, and that nothing else goes with them.

    private func inMonth(_ date: Date, _ txns: [Txn]) -> [String] {
        Txn.inMonth(of: date, from: txns).map(\.merchant)
    }

    @Test func onlyTheMonthAskedForIsShown() {
        let september = charge("SEPTEMBER", arrived: date(2026, 9, 30, 10, 0))
        let october = charge("OCTOBER", arrived: date(2026, 10, 1, 9, 0))

        #expect(inMonth(date(2026, 10, 15), [september, october]) == ["OCTOBER"])
        #expect(inMonth(date(2026, 9, 15), [september, october]) == ["SEPTEMBER"])
    }

    /// The reason the filter keys on `occurredAt`: a purchase made on the 30th and heard about
    /// on the 3rd belongs to the month it was spent in, not the month it arrived in.
    @Test func theMonthComesFromThePurchaseDayNotTheArrival() {
        let lateArrival = datedCharge(
            "MADE IN SEPTEMBER", purchasedOn: date(2026, 9, 30), arrived: date(2026, 10, 3, 8, 0))

        #expect(inMonth(date(2026, 10, 15), [lateArrival]).isEmpty)
        #expect(inMonth(date(2026, 9, 15), [lateArrival]) == ["MADE IN SEPTEMBER"])
    }

    /// The boundary itself: 23:59 on the last day against 00:01 on the first.
    @Test func theBoundaryIsTheCalendarMonth() {
        let lastMinute = charge("LAST MINUTE", arrived: date(2026, 9, 30, 23, 59))
        let firstMinute = charge("FIRST MINUTE", arrived: date(2026, 10, 1, 0, 1))

        #expect(inMonth(date(2026, 9, 30), [lastMinute, firstMinute]) == ["LAST MINUTE"])
        #expect(inMonth(date(2026, 10, 1), [lastMinute, firstMinute]) == ["FIRST MINUTE"])
    }

    @Test func depositsAreFilteredByMonthLikeEverythingElse() {
        let deposit = Txn(
            amountMinor: 25_000, currencyCode: "USD", cardSuffix: "", merchant: "ZELLE",
            receivedAt: date(2026, 9, 20), occurredAt: date(2026, 9, 20),
            occurredAtIsFromMessage: false, parserVersion: 1, kind: .deposit)

        #expect(inMonth(date(2026, 10, 5), [deposit]).isEmpty)
        #expect(inMonth(date(2026, 9, 5), [deposit]) == ["ZELLE"])
    }

    /// The two rules compose: the month picks the rows, the order arranges them.
    @Test func aFilteredMonthIsStillOrderedNewestFirst() {
        let early = charge("EARLY", arrived: date(2026, 10, 2, 9, 0))
        let late = charge("LATE", arrived: date(2026, 10, 20, 9, 0))
        let otherMonth = charge("SEPTEMBER", arrived: date(2026, 9, 5, 9, 0))

        let rows = Txn.feedOrder(
            Txn.inMonth(of: date(2026, 10, 15), from: [early, late, otherMonth]))
        #expect(rows.map(\.merchant) == ["LATE", "EARLY"])
    }

    // MARK: - Edges

    @Test func anEmptyFeedStaysEmpty() {
        #expect(Txn.feedOrder([]).isEmpty)
    }

    /// The comparator has to be a total order for `sorted(by:)` to mean anything. This is the
    /// shape that broke the pairwise rule: a timed charge, a date-only charge, and another
    /// timed one, arranged so that "compare times when both have them, otherwise arrival"
    /// wants A<B, B<C and C<A simultaneously.
    @Test func aMixedShuffleOrderIsStableAndReversible() {
        let a = charge("A", arrived: date(2026, 9, 20, 1, 0))                      // occurredAt 01:00
        let c = datedCharge("C", purchasedOn: date(2026, 9, 20), arrived: date(2026, 9, 20, 5, 0))
        let b = charge("B", arrived: date(2026, 9, 20, 9, 0))                      // occurredAt 09:00

        // By arrival: B (09:00), C (05:00), A (01:00).
        #expect(order([a, b, c]) == ["B", "C", "A"])
        // Every permutation has to agree, or the comparator is inconsistent.
        #expect(order([c, a, b]) == ["B", "C", "A"])
        #expect(order([b, c, a]) == ["B", "C", "A"])
    }
}
