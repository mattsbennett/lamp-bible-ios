import XCTest

final class Lamp_BibleUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchOffersNavigationAndCanOpenSettings() {
        let app = XCUIApplication()
        app.launch()
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Read"].exists)
        XCTAssertTrue(app.buttons["Search"].exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }
}
