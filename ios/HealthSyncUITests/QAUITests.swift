import UIKit
import XCTest

/// QA pass (2026-09-29): accessibility audit, largest Dynamic Type, dark mode, launch time and
/// flow edge cases, against the in-memory fakes (-uiTesting). Audit issues and small preview
/// screenshots are printed to the log with a "QA-" prefix so they can be read from CI output.
final class QAUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + extra
        app.launch()
        return app
    }

    private static let xxxl = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    /// Full-size screenshot as a test attachment, plus a small JPEG preview in the log.
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let image = screenshot.image
        let scale: CGFloat = 300 / max(image.size.width, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        if let jpeg = small.jpegData(compressionQuality: 0.55) {
            print("QA-SHOT \(name) \(jpeg.base64EncodedString())")
        }
    }

    private func audit(_ app: XCUIApplication, _ screen: String) {
        do {
            try app.performAccessibilityAudit { issue in
                let label = issue.element.map { "\($0.elementType.rawValue):\($0.label)" } ?? "-"
                print("QA-A11Y [\(screen)] \(issue.auditType.rawValue) | \(issue.compactDescription) | \(label)")
                return true // record, don't fail: findings go to the report
            }
        } catch {
            print("QA-A11Y [\(screen)] audit error: \(error)")
        }
    }

    /// The -uiTesting build still uses the real Keychain, so a link created by an earlier test
    /// survives relaunch and the sheet would skip consent. "Delete All My Data" clears it.
    private func launchFresh(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(extra + ["-onboarded"])
        XCTAssertTrue(app.buttons["moreMenu"].waitForExistence(timeout: 5))
        app.buttons["moreMenu"].tap()
        app.buttons["Delete All My Data"].firstMatch.tap()
        let confirm = app.sheets.buttons["Delete All My Data"].exists ? app.sheets.buttons["Delete All My Data"] : app.buttons["Delete All My Data"].firstMatch
        confirm.tap()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
        return app
    }

    private func openClaudeSteps(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        app.buttons["provider.claude"].tap()
        XCTAssertTrue(app.buttons["consentContinue"].waitForExistence(timeout: 5))
    }

    /// Consent may sit below the fold at large text sizes: scroll to it if needed.
    private func tapContinue(_ app: XCUIApplication) {
        let cont = app.buttons["consentContinue"]
        if !cont.isHittable {
            print("QA-FLOW consentContinue not hittable without scrolling")
            app.swipeUp()
        }
        cont.tap()
    }

    // MARK: Accessibility

    func testAccessibilityAuditAllScreens() {
        let app = launchFresh()
        audit(app, "welcome")
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        audit(app, "home")
        openClaudeSteps(app)
        audit(app, "consent")
        tapContinue(app)
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 5))
        audit(app, "steps")
    }

    func testLargestDynamicTypeLayouts() {
        let app = launchFresh(Self.xxxl)
        let connect = app.buttons["connectHealth"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        shot("qa-xxxl-01-welcome")
        XCTAssertTrue(connect.isHittable, "Connect button reachable at the largest text size")
        audit(app, "welcome-xxxl")
        connect.tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        shot("qa-xxxl-02-home")
        audit(app, "home-xxxl")
        openClaudeSteps(app)
        shot("qa-xxxl-03-consent")
        print("QA-FLOW xxxl consentContinue hittable without scrolling: \(app.buttons["consentContinue"].isHittable)")
        tapContinue(app)
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 5))
        shot("qa-xxxl-04-steps")
        audit(app, "steps-xxxl")
    }

    /// Runs in the second pass of qa-ios.yml, after `simctl ui appearance dark`.
    func testDarkModeScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["QA_APPEARANCE"] == "dark", "dark pass only")
        let app = launchFresh()
        shot("qa-dark-01-welcome")
        audit(app, "welcome-dark")
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        shot("qa-dark-02-home")
        openClaudeSteps(app)
        shot("qa-dark-03-consent")
        tapContinue(app)
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 5))
        shot("qa-dark-04-steps")
        audit(app, "steps-dark")
    }

    func testLightModeReferenceScreens() {
        let app = launch()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
        shot("qa-light-01-welcome")
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        shot("qa-light-02-home")
        app.buttons["moreMenu"].tap()
        shot("qa-light-03-menu")
        XCTAssertTrue(app.buttons["Help & Support"].exists || app.links["Help & Support"].exists)
        XCTAssertTrue(app.buttons["Privacy Policy"].exists || app.links["Privacy Policy"].exists)
    }

    // MARK: Performance

    func testLaunchTime() {
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTApplicationLaunchMetric()], options: options) {
            let app = XCUIApplication()
            app.launchArguments = ["-uiTesting", "-onboarded"]
            app.launch()
        }
    }

    // MARK: Flows

    /// Closing the sheet before the assistant connects, then reopening, resumes at the steps
    /// (the link was already created) instead of asking for consent again.
    func testReopeningSetupResumesAtSteps() {
        let app = launchFresh()
        app.buttons["connectHealth"].tap()
        openClaudeSteps(app)
        tapContinue(app)
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 5))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        app.buttons["provider.claude"].tap()
        // Either still waiting (steps) or already set up (fake backend connects after ~2 s).
        let resumed = app.buttons["copyLink"].waitForExistence(timeout: 5) || app.buttons["disconnect"].exists
        XCTAssertTrue(resumed)
        XCTAssertFalse(app.buttons["consentContinue"].exists, "consent should not be asked twice")
    }

    func testDisconnectReturnsRowToNotSetUp() {
        let app = launchFresh()
        app.buttons["connectHealth"].tap()
        openClaudeSteps(app)
        tapContinue(app)
        let row = app.buttons["provider.claude"]
        expectation(for: NSPredicate(format: "value == 'Set up'"), evaluatedWith: row)
        waitForExpectations(timeout: 20)
        row.tap()
        XCTAssertTrue(app.buttons["disconnect"].waitForExistence(timeout: 5))
        app.buttons["disconnect"].tap()
        let confirm = app.sheets.buttons["Disconnect"].exists ? app.sheets.buttons["Disconnect"] : app.buttons["Disconnect"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        expectation(for: NSPredicate(format: "value == 'Not set up'"), evaluatedWith: row)
        waitForExpectations(timeout: 10)
        shot("qa-flow-disconnected")
    }

    func testCancellingDeleteKeepsHome() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["moreMenu"].waitForExistence(timeout: 5))
        app.buttons["moreMenu"].tap()
        app.buttons["Delete All My Data"].firstMatch.tap()
        shot("qa-flow-delete-confirm")
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 3) { cancel.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap() }
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["connectHealth"].exists)
    }

    /// Rapid double tap on Continue must not create two links (the second revokes the first).
    func testDoubleTapContinue() {
        let app = launchFresh()
        app.buttons["connectHealth"].tap()
        openClaudeSteps(app)
        let cont = app.buttons["consentContinue"]
        cont.tap()
        if cont.exists && cont.isHittable {
            cont.tap()
            print("QA-FLOW consentContinue still tappable after first tap (no busy/disabled state)")
        }
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 5))
    }

    /// After "Delete All My Data" the user must be able to connect again without restarting.
    func testReonboardAfterDelete() {
        let app = launchFresh()
        let connect = app.buttons["connectHealth"]
        let enabled = NSPredicate(format: "isEnabled == true")
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: enabled, object: connect)], timeout: 20)
        print("QA-FLOW after delete: connectHealth enabled within 20 s = \(result == .completed)")
        shot("qa-flow-after-delete-20s")
        connect.tap()
        let home = app.buttons["provider.claude"].waitForExistence(timeout: 10)
        print("QA-FLOW after delete: reached home without relaunch = \(home)")
        if !home {
            app.terminate()
            let again = launch()
            XCTAssertTrue(again.buttons["connectHealth"].waitForExistence(timeout: 5))
            again.buttons["connectHealth"].tap()
            print("QA-FLOW after delete: reached home after relaunch = \(again.buttons["provider.claude"].waitForExistence(timeout: 10))")
        }
        XCTAssertTrue(home, "user can reconnect after deleting data, without restarting the app")
    }

    func testHomeSyncStatusText() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        let texts = app.staticTexts.allElementsBoundByIndex.map(\.label)
        print("QA-TEXT home: \(texts)")
        shot("qa-home-status")
    }
}
