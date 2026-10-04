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

    /// Types `text` into a field, replacing whatever is already in it.
    ///
    /// The trailing-edge tap is load-bearing. A centre tap on a trailing-aligned field drops
    /// the caret at the START of the text, which makes the deletes no-ops and prepends the new
    /// value — that is how this first produced "1234.560.00" instead of "1234.56".
    ///
    /// Only for fields near the top of a form. A coordinate tap does not scroll, so on a field
    /// low enough to sit under the keyboard it lands on the keyboard and the type fails with
    /// "neither element nor any descendant has keyboard focus".
    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        // An empty field reports its placeholder as the value; the deletes are no-ops there.
        let existing = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        field.typeText(text)
    }

    /// Waits for the bank figure to read `expected`.
    ///
    /// Waited on rather than read straight after a tap: the button exists the whole time
    /// behind a sheet, so an immediate read returns the value from before the change.
    @MainActor
    private func expectBank(_ expected: String, of bank: XCUIElement, _ message: String) {
        let matched = NSPredicate(format: "value == %@", expected)
        let finished = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: matched, object: bank)],
            timeout: 5
        )
        XCTAssertEqual(finished, .completed,
                       "\(message), saw \(String(describing: bank.value))")
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

    /// The month picker is a `.principal` toolbar item, so it *is* the title — and the
    /// navigation bar therefore has no label of its own to match on. This looks for the button
    /// instead, and checks it names a month.
    @MainActor
    func testLedgerIsTheFirstScreen() throws {
        let app = XCUIApplication()
        app.launch()

        let title = app.buttons["Month"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(title.label.hasSuffix("Spending"), "saw \(title.label)")
    }

    /// The title is the month picker: tapping it offers the recent months, and choosing one
    /// switches the whole screen — total, list and all — to that month.
    @MainActor
    func testTheMonthPickerSwitchesWhichMonthIsShown() throws {
        let app = XCUIApplication()
        app.launch()

        let picker = app.buttons["Month"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))

        // Computed rather than hard-coded, so this does not start failing the moment the
        // calendar moves on.
        let previous = Calendar.current.date(byAdding: .month, value: -1, to: Date())!
        let previousName = previous.formatted(.dateTime.month(.wide))
        let previousLabel = previous.formatted(.dateTime.month(.wide).year())

        picker.tap()

        let option = app.buttons[previousLabel]
        XCTAssertTrue(option.waitForExistence(timeout: 5),
                      "\(previousLabel) should be offered, saw \(app.buttons.count) buttons")
        option.tap()

        // The title follows the selection, and names the month rather than the year.
        let retitled = app.buttons["Month"]
        XCTAssertTrue(retitled.waitForExistence(timeout: 5))
        XCTAssertTrue(retitled.label.contains(previousName), "saw \(retitled.label)")
        XCTAssertFalse(retitled.label.contains("October"),
                       "the title should no longer be showing the current month")
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

    /// Both figures in the summary row. Asserted on the labels rather than the amounts, which
    /// depend on what happens to be in the store, and rather than the month, which is dynamic.
    @MainActor
    func testTotalSpendSectionIsShown() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Balance"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Bank"].exists)
        XCTAssertTrue(app.staticTexts["Remaining"].exists)
    }

    /// The bank balance is the one figure that is typed rather than derived, so the sheet has
    /// to actually write it back. A sheet that opens and saves nothing looks identical to one
    /// that works.
    @MainActor
    func testBankBalanceCanBeSet() throws {
        let app = XCUIApplication()
        app.launch()

        let bank = app.buttons["Bank balance"]
        XCTAssertTrue(bank.waitForExistence(timeout: 10))
        bank.tap()

        XCTAssertTrue(app.navigationBars["Bank balance"].waitForExistence(timeout: 5))

        // The field opens on whatever is stored, which persists across launches, so it is
        // replaced rather than typed over.
        let field = app.textFields["Amount"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(in: field, with: "1234.56")

        // Pinned before saving, so a failure below says which half is wrong: the amount never
        // reaching the field, or the sheet failing to store it.
        XCTAssertEqual(field.value as? String, "1234.56",
                       "the amount field should hold what was typed")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled, "a well-formed amount should enable Save")
        save.tap()

        // The sheet only closes once `save()` has got past its guard, so this separates "the
        // save ran" from "the figure updated". Without it, a value that never changes is
        // indistinguishable from a sheet that never saved.
        XCTAssertTrue(app.navigationBars["Bank balance"].waitForNonExistence(timeout: 5),
                      "the sheet should close when saved")

        expectBank("$1,234.56", of: bank, "saving should update the figure behind the sheet")
    }

    /// Editing appends a journal line rather than changing the row in place, so what this
    /// proves is the round trip: tapping opens the form filled in, and Save lands the change
    /// back on the row it came from.
    @MainActor
    func testATransactionCanBeEditedByTappingIt() throws {
        let app = XCUIApplication()
        app.launch()

        app.buttons["Add manually"].tap()
        replaceText(in: app.textFields["Merchant"], with: "UITEST EDITME")
        replaceText(in: app.textFields["Amount"], with: "5.00")
        // No card: it is optional, and the field sits low enough to be under the keyboard once
        // the amount has been typed, where a coordinate tap lands on the keyboard instead.
        app.buttons["Save"].tap()
        app.buttons["Cancel"].tap()

        let row = app.staticTexts["UITEST EDITME"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.navigationBars["Edit charge"].waitForExistence(timeout: 5),
                      "tapping a row should open it for editing")

        // Filled in rather than blank — a form that opened empty would be a second add wearing
        // an edit's title, and the row behind it would be untouched.
        let amount = app.textFields["Amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertEqual(amount.value as? String, "5.00",
                       "the form should open on the values already stored")

        replaceText(in: amount, with: "9.00")
        app.buttons["Save"].tap()
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["$9.00"].waitForExistence(timeout: 5),
                      "the edited amount should be showing on the row")
        XCTAssertTrue(app.staticTexts["UITEST EDITME"].exists, "and it should be the same row")
    }

    /// A deposit is the one entry that changes the bank balance rather than the ledger, so it
    /// has its own tab, its own sign rule, and its own arithmetic.
    @MainActor
    func testDepositAddsToAndSubtractsFromTheBank() throws {
        let app = XCUIApplication()
        app.launch()

        // Pinned first, so the assertions below do not depend on whatever an earlier run left
        // in UserDefaults.
        let bank = app.buttons["Bank balance"]
        XCTAssertTrue(bank.waitForExistence(timeout: 10))
        bank.tap()
        let bankField = app.textFields["Amount"]
        XCTAssertTrue(bankField.waitForExistence(timeout: 5))
        replaceText(in: bankField, with: "100.00")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Bank balance"].waitForNonExistence(timeout: 5))
        expectBank("$100.00", of: bank, "the balance should be pinned before depositing")

        app.buttons["Add manually"].tap()
        XCTAssertTrue(app.buttons["Deposit"].waitForExistence(timeout: 5))
        app.buttons["Deposit"].tap()

        // A deposit has no card field at all.
        XCTAssertFalse(app.textFields["Last 4 or 5 digits"].exists,
                       "the deposit tab should not offer a card")

        replaceText(in: app.textFields["Merchant"], with: "UITEST DEPOSIT")
        replaceText(in: app.textFields["Amount"], with: "25.00")
        app.buttons["Save"].tap()
        expectBank("$125.00", of: bank, "a deposit should add to the bank")

        // The point of the whole change: a deposit is a transaction, not only an adjustment to
        // the bank. It has to be visible in the list like anything else.
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["UITEST DEPOSIT"].waitForExistence(timeout: 5),
                      "a deposit should appear in the transactions")

        app.buttons["Add manually"].tap()
        app.buttons["Deposit"].tap()

        // The same tab, a minus. This is the rule that separates a deposit from a charge:
        // `Money` refuses a negative charge outright, and here it has to be accepted.
        replaceText(in: app.textFields["Merchant"], with: "UITEST WITHDRAWAL")
        replaceText(in: app.textFields["Amount"], with: "-40.00")
        app.buttons["Save"].tap()
        expectBank("$85.00", of: bank, "a negative deposit should subtract from the bank")
    }

    /// Deleting a line from the Raw journal, which is the only place a body that recorded no
    /// transaction can be removed — the feed deletes rows, and that line has none.
    ///
    /// Everything structural about the feature is invisible to the unit tests: the `.onDelete`
    /// wiring, resolving a swipe's offsets back to the array that was drawn, the confirmation,
    /// and the reload that makes the line and its transaction disappear together. A screen that
    /// compiles perfectly and does none of it passes every unit test in the target.
    @MainActor
    func testDeleteALineFromTheRawJournal() throws {
        let app = XCUIApplication()
        app.launch()

        // A hand-typed alert takes the same path as a captured one, and lands in the journal.
        app.buttons["Add manually"].tap()
        replaceText(in: app.textFields["Merchant"], with: "UITEST JOURNAL")
        replaceText(in: app.textFields["Amount"], with: "7.77")
        app.buttons["Save"].tap()
        app.buttons["Cancel"].tap()

        XCTAssertTrue(app.staticTexts["UITEST JOURNAL"].waitForExistence(timeout: 5),
                      "the charge should be in the feed before the journal is opened")

        app.buttons["More"].tap()
        let rawJournal = app.buttons["Raw journal"]
        XCTAssertTrue(rawJournal.waitForExistence(timeout: 5))
        rawJournal.tap()
        XCTAssertTrue(app.navigationBars["Raw journal"].waitForExistence(timeout: 5))

        // Matched on the composed body, not the merchant: the feed row behind this sheet
        // carries the bare merchant as its own label, and a bare merchant match would pick it
        // up and swipe something that is not on screen.
        let line = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@",
                        "Manual | ", "UITEST JOURNAL")
        ).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5), "the line should be listed in the journal")
        line.swipeLeft()

        let swipeDelete = app.buttons["Delete"]
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 5), "swiping should reveal Delete")
        swipeDelete.tap()

        // The confirmation is the feature, not a nicety: the journal is the app's only copy of
        // what arrived, so the swipe alone must not destroy it.
        XCTAssertTrue(app.staticTexts["Delete this journal line?"].waitForExistence(timeout: 5),
                      "deleting a journal line should ask first")
        let confirm = app.buttons["Delete line"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

        // And the transaction it recorded goes with it — the store is rebuilt from this file,
        // so a row left behind would simply come back.
        XCTAssertFalse(app.staticTexts["UITEST JOURNAL"].waitForExistence(timeout: 3),
                       "deleting the line should take the transaction it recorded")
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
