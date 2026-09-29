import XCTest

final class AuditUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func launch(_ args: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + args
        app.launch(); return app
    }
    /// Runs Apple's accessibility audit. If the audit tool itself times out (error -56, which happens on
    /// slow CI machines and says nothing about the app), it is run once more. Real findings still fail.
    private func audit(_ app: XCUIApplication) throws {
        do {
            try app.performAccessibilityAudit()
        } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 {
            try app.performAccessibilityAudit()
        }
    }
    func testWelcomeAccessibilityAndCapture() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 10))
        shot("audit-welcome")
        try audit(app)
    }
    func testHomeAccessibilityAndCapture() throws {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["provider.chatgpt"].waitForExistence(timeout: 10))
        shot("audit-home")
        try audit(app)
    }
    func testLargeTextWelcomeAndHome() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 10))
        shot("audit-largest-text-welcome")
        XCTAssertTrue(app.buttons["connectHealth"].isHittable)
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["provider.chatgpt"].waitForExistence(timeout: 10))
        shot("audit-largest-text-home")
        app.buttons["provider.chatgpt"].tap()
        shot("audit-largest-text-consent")
    }
    func testChatGPTConsentCanBeCancelled() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["provider.chatgpt"].waitForExistence(timeout: 10))
        app.buttons["provider.chatgpt"].tap()
        XCTAssertTrue(app.buttons["consentContinue"].waitForExistence(timeout: 10))
        shot("audit-chatgpt-consent")
        app.buttons["Close"].tap()
        XCTAssertEqual(app.buttons["provider.chatgpt"].value as? String, "Not set up")
    }
    func testLaunchPerformance() {
        measure(metrics: [XCTApplicationLaunchMetric()]) { XCUIApplication().launchArguments = ["-uiTesting"]; let app = XCUIApplication(); app.launchArguments = ["-uiTesting"]; app.launch() }
    }
}
