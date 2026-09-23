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

    /// The card rule the form enforces: four or five digits, nothing else.
    @MainActor
    func testCardFieldRejectsTooFewDigits() throws {
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

        card.tap()
        card.typeText("123")
        XCTAssertFalse(save.isEnabled, "three digits should not be enough")

        card.typeText("4")
        XCTAssertTrue(save.isEnabled, "four digits should be enough")
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
