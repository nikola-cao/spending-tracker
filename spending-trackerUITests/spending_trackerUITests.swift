//
//  spending_trackerUITests.swift
//  spending-trackerUITests
//
//  The unit tests never touch SwiftUI, so a screen that crashes on presentation would pass
//  every one of them. These exist only to prove the screens open and are reachable.
//

import XCTest

final class spending_trackerUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Flips a Form toggle.
    ///
    /// `element.tap()` taps the element's CENTRE, which on a full-width form row is empty
    /// space beside the label — and that does not toggle anything. The switch control sits at
    /// the trailing edge, so the tap is aimed there. This is a well-known trap: the element
    /// exists, is hittable, accepts the tap, and simply does nothing.
    @MainActor
    private func flip(_ toggle: XCUIElement, _ app: XCUIApplication) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        // Waited on, because SwiftUI re-renders asynchronously and reading the value straight
        // after the tap returns the state from before it.
        let expected = (toggle.value as? String) == "0" ? "1" : "0"
        let flipped = NSPredicate(format: "value == %@", expected)
        _ = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: flipped, object: toggle)],
            timeout: 5
        )
    }

    /// A compact dump of the parts of the screen this suite reasons about, so a failed
    /// assertion reports the state instead of just the expectation.
    @MainActor
    private func state(_ app: XCUIApplication) -> String {
        let switches = (0..<app.switches.count).map { index -> String in
            let element = app.switches.element(boundBy: index)
            return "\(element.label)=\(String(describing: element.value))"
        }
        let pickers = (0..<app.datePickers.count).map { index in
            app.datePickers.element(boundBy: index).identifier
        }
        return "datePickers=\(pickers) switches=\(switches)"
    }

    @MainActor
    func testLedgerIsTheFirstScreen() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spending"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testManualEntryScreenOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let add = app.buttons["Add manually"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()

        XCTAssertTrue(app.navigationBars["Add manually"].waitForExistence(timeout: 5))

        // Every field is present, and Save stays disabled until they are filled in.
        XCTAssertTrue(app.textFields["Merchant"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Amount"].exists)
        XCTAssertTrue(app.textFields["Last 4 or 5 digits"].exists)

        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled, "Save should be disabled while the form is empty")
    }

    /// The card rule the form enforces: optional, but four or five digits when given.
    @MainActor
    func testCardFieldIsOptionalButValidated() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Add manually"].tap()

        let merchant = app.textFields["Merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5))
        merchant.tap()
        merchant.typeText("UITEST MERCHANT")

        let amount = app.textFields["Amount"]
        amount.tap()
        amount.typeText("1.00")

        let save = app.buttons["Save"]
        let card = app.textFields["Last 4 or 5 digits"]

        // Merchant and amount alone are enough — the card is optional.
        XCTAssertTrue(save.isEnabled, "the card should be optional")

        // A card that IS filled in still has to be well-formed.
        card.tap()
        card.typeText("123")
        XCTAssertFalse(save.isEnabled, "three digits should not be enough")

        card.typeText("4")
        XCTAssertTrue(save.isEnabled, "four digits should be enough")
    }

    /// Typing past five digits: the extras simply never appear, rather than being accepted and
    /// then refused on save.
    @MainActor
    func testCardFieldStopsAtFiveDigits() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Add manually"].tap()

        let card = app.textFields["Last 4 or 5 digits"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        card.typeText("12345678")

        XCTAssertEqual(card.value as? String, "12345",
                       "characters past the fifth should not show up")
    }

    /// The date is optional, and switching it off hides the picker without changing how a date
    /// is chosen when it is on.
    @MainActor
    func testDateCanBeTurnedOff() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["Add manually"].tap()

        let toggle = app.switches["Set a purchase date"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))

        let picker = app.datePickers.firstMatch
        XCTAssertTrue(picker.exists, "the picker should be there by default")

        let before = state(app)

        flip(toggle, app)
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5),
                      "turning the date off should hide the picker. before[\(before)] "
                      + "after[\(state(app))]")

        flip(toggle, app)
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 5),
                      "turning it back on should restore it")
    }

    /// Adds a charge through the real UI and deletes it through the real UI. Unit tests cover
    /// the store and journal side; this is the only thing that proves the swipe action is
    /// actually wired up, which is exactly the kind of gap that compiles cleanly and does
    /// nothing.
    @MainActor
    func testAddThenSwipeToDeleteACharge() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Add manually"].tap()

        let merchant = app.textFields["Merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 5))
        merchant.tap()
        merchant.typeText("UITEST MERCHANT")

        let amount = app.textFields["Amount"]
        amount.tap()
        amount.typeText("4.44")

        let card = app.textFields["Last 4 or 5 digits"]
        card.tap()
        card.typeText("7224")

        app.buttons["Save"].tap()
        app.buttons["Cancel"].tap()

        let row = app.staticTexts["UITEST MERCHANT"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the charge should appear in the feed")

        row.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "swiping should reveal Delete")
        delete.tap()

        XCTAssertFalse(app.staticTexts["UITEST MERCHANT"].waitForExistence(timeout: 3),
                       "the charge should be gone once deleted")
    }

    @MainActor
    func testTotalSpendSectionIsShown() throws {
        let app = XCUIApplication()
        app.launch()

        // The total is headed by the current month, which is dynamic — assert the row that
        // states the charge count instead, which only the total section renders.
        let summary = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH %@", " charges")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
    }

    @MainActor
    func testDiagnosticsScreenOpens() throws {
        let app = XCUIApplication()
        app.launch()

        let more = app.buttons["More"]
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        more.tap()

        let diagnostics = app.buttons["Diagnostics"]
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
        diagnostics.tap()

        XCTAssertTrue(app.navigationBars["Diagnostics"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Charges recorded"].waitForExistence(timeout: 5))
    }
}
