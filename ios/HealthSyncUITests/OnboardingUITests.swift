import XCTest

/// Runs the real UI against in-memory fakes (launch argument -uiTesting). Also captures the
/// App Store screenshots.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-noChicago"] + extra
        app.launch()
        return app
    }

    private func snapshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testWelcomeToHome() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["KROK"].waitForExistence(timeout: 5))
        snapshot("01-Welcome")
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["provider.chatgpt"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["heroMetric"].waitForExistence(timeout: 5))
    }

    func testChicagoArtShowsWhileActive() {
        let app = launch(["-chicago"])
        XCTAssertTrue(app.staticTexts["CHICAGO MARATHON"].waitForExistence(timeout: 5))
        snapshot("00-Welcome-Chicago")
    }

    func testConnectClaudeShowsSetUpCheckmark() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        snapshot("02-Home")
        app.buttons["provider.claude"].tap()
        XCTAssertTrue(app.buttons["consentContinue"].waitForExistence(timeout: 30))
        app.buttons["consentContinue"].tap()
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 30))
        snapshot("03-Steps")
        app.buttons["copyLink"].tap()
        XCTAssertTrue(app.buttons["Copied"].waitForExistence(timeout: 30))
        // The fake backend reports Claude as set up shortly after; the sheet closes itself.
        let setUp = NSPredicate(format: "value == 'Set up'")
        expectation(for: setUp, evaluatedWith: app.buttons["provider.claude"])
        waitForExpectations(timeout: 60)
        snapshot("04-Connected")

        // Re-opening shows the connected state with Disconnect.
        app.buttons["provider.claude"].tap()
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5))
    }

    func testDeleteAllDataReturnsToWelcome() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["moreMenu"].waitForExistence(timeout: 5))
        app.buttons["moreMenu"].tap()
        app.buttons["Delete All My Data"].firstMatch.tap()
        let confirm = app.sheets.buttons["Delete All My Data"].exists ? app.sheets.buttons["Delete All My Data"] : app.buttons["Delete All My Data"].firstMatch
        confirm.tap()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
    }
}
