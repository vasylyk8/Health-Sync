import UIKit
import XCTest

/// Runs the real UI against in-memory fakes (launch argument -uiTesting). Also captures the
/// App Store screenshots.
final class OnboardingUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (extra.contains("-specialEdition") ? [] : ["-noSpecialEdition"]) + extra
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
        app.signInThroughAccountPage()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["provider.chatgpt"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["heroMetric"].waitForExistence(timeout: 5))
    }

    func testMedalAppearsWhenTheUploadIsDoneAndTakesAFinishTime() {
        let app = launch(["-specialEdition"])
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
        app.buttons["connectHealth"].tap()
        app.signInThroughAccountPage()
        XCTAssertTrue(app.buttons["editionMedal"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["READY FOR CHICAGO?"].exists)
        snapshot("03a-Home-Medal")
        app.buttons["editionMedal"].tap()
        XCTAssertTrue(app.buttons["editionDone"].waitForExistence(timeout: 5))
        snapshot("03b-Home-Medal-Picker")
        app.buttons["editionDone"].tap()
        let ask = app.buttons["askPrompt"]
        XCTAssertTrue(ask.waitForExistence(timeout: 5))
        XCTAssertTrue(ask.label.contains("4:30"), "the question names the goal")
        snapshot("03c-Home-Medal-Ask")
    }

    func testAppleAccountCanUsePublicOAuthWithoutCreatingAPrivateLink() {
        let app = launch(["-onboarded", "-appleLinked"])
        // Home has no "linked" row to wait for: the account state loads a moment after launch, so open the sheet
        // until it shows the OAuth view (an unlinked account would show the consent view instead).
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 10))
        var oauth = false
        for _ in 0..<10 where !oauth {
            app.buttons["provider.claude"].tap()
            oauth = app.buttons["copyOAuthURL"].waitForExistence(timeout: 3)
            if !oauth {
                if app.buttons["Close"].waitForExistence(timeout: 2) { app.buttons["Close"].tap() }
                _ = app.buttons["provider.claude"].waitForExistence(timeout: 2)
            }
        }
        XCTAssertTrue(oauth, "a linked account sets up through OAuth")
        XCTAssertFalse(app.buttons["consentContinue"].exists)
        app.buttons["copyOAuthURL"].tap()
        XCTAssertTrue(app.staticTexts["oauthCopied"].waitForExistence(timeout: 5))
        snapshot("05-Apple-OAuth-Setup")
    }

    func testAccountPageFollowsHealthAndIsRequired() {
        let app = launch()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["appleSignIn"].exists, "Welcome no longer offers Sign in with Apple")
        app.buttons["connectHealth"].tap()
        XCTAssertTrue(app.buttons["appleSignIn"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["connectHealth"].waitForNonExistence(timeout: 5), "the connect button has faded out")
        XCTAssertFalse(app.buttons["provider.claude"].exists, "no way past the account page without signing in")
        snapshot("01b-Account")
        app.signInThroughAccountPage()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["appleSignIn"].exists, "Home no longer offers Sign in with Apple")
    }

    func testLogOutReturnsToWelcomeAndCanSignInAgain() {
        let app = launch(["-onboarded", "-appleLinked"])
        XCTAssertTrue(app.buttons["moreMenu"].waitForExistence(timeout: 10))
        // The account state loads a moment after launch; Log out shows once it says the Apple Account is linked.
        var logOut = false
        for _ in 0..<10 where !logOut {
            app.buttons["moreMenu"].tap()
            logOut = app.buttons["Log out"].firstMatch.waitForExistence(timeout: 2)
            if !logOut { app.tap() }
        }
        XCTAssertTrue(logOut, "a linked account can log out")
        app.buttons["Log out"].firstMatch.tap()
        let confirm = app.sheets.buttons["Log out"].exists ? app.sheets.buttons["Log out"] : app.buttons["Log out"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["connectHealth"].waitForExistence(timeout: 10), "back on page 1")
        XCTAssertFalse(app.buttons["provider.claude"].exists)
        app.buttons["connectHealth"].tap()
        app.signInThroughAccountPage()
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 10), "signing in again gets back to Home")
    }

    func testReopeningBeforeSigningInReturnsToTheAccountPage() {
        let app = launch(["-accountPending"])
        XCTAssertTrue(app.buttons["appleSignIn"].waitForExistence(timeout: 10))
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

    /// What is on screen, as text: element names, plus a small screenshot (base64 JPEG) to decode from the CI log.
    private func diagnostics(_ app: XCUIApplication) -> String {
        let buttons = app.buttons.allElementsBoundByIndex.prefix(25).map { "\($0.identifier)/\($0.label)" }.joined(separator: ", ")
        let others = app.otherElements.allElementsBoundByIndex.map(\.identifier).filter { !$0.isEmpty }.prefix(25).joined(separator: ", ")
        let image = XCUIScreen.main.screenshot().image
        let scale = 220 / max(image.size.width, 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        let jpeg = small.jpegData(compressionQuality: 0.4)?.base64EncodedString() ?? "-"
        return "state=\(app.state.rawValue) safari=\(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state.rawValue) BUTTONS: \(buttons) OTHERS: \(others) SHOT: \(jpeg)"
    }

    /// "Open claude.ai" shows the page in an in-app browser. A plain openURL would leave the app
    /// (Safari here, the Claude app on a phone that has it installed).
    private func assertOpensInAppBrowser(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let open = app.buttons["openWebsite"]
        XCTAssertTrue(open.waitForExistence(timeout: 30), "the Open button is shown", file: file, line: line)
        open.tap()
        // The browser is hosted out of process; depending on the iOS version its controls show up in KROK's tree.
        let done = app.buttons["Done"]
        let shown = done.waitForExistence(timeout: 20)
            || app.otherElements["SFSafariViewController"].exists
            || app.otherElements["TopBrowserBar"].exists
        XCTAssertTrue(shown, "the page opens in an in-app browser. \(diagnostics(app))", file: file, line: line)
        XCTAssertEqual(app.state, .runningForeground, "KROK stays in front", file: file, line: line)
        XCTAssertNotEqual(XCUIApplication(bundleIdentifier: "com.apple.mobilesafari").state, .runningForeground,
                          "the link does not leave the app", file: file, line: line)
        snapshot("06-In-App-Browser")
        if done.exists { done.tap() }
        XCTAssertTrue(open.waitForExistence(timeout: 10), "closing the browser returns to the setup sheet", file: file, line: line)
    }

    func testOpenWebsiteOpensInAppBrowserOnTheStepsScreen() {
        let app = launch(["-onboarded"])
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 5))
        app.buttons["provider.claude"].tap()
        XCTAssertTrue(app.buttons["consentContinue"].waitForExistence(timeout: 30))
        app.buttons["consentContinue"].tap()
        XCTAssertTrue(app.buttons["copyLink"].waitForExistence(timeout: 30))
        assertOpensInAppBrowser(app)
    }

    func testOpenWebsiteOpensInAppBrowserOnTheAppleAccountScreen() {
        let app = launch(["-onboarded", "-appleLinked"])
        XCTAssertTrue(app.buttons["provider.claude"].waitForExistence(timeout: 10))
        var oauth = false
        for _ in 0..<10 where !oauth {
            app.buttons["provider.claude"].tap()
            oauth = app.buttons["copyOAuthURL"].waitForExistence(timeout: 3)
            if !oauth {
                if app.buttons["Close"].waitForExistence(timeout: 2) { app.buttons["Close"].tap() }
                _ = app.buttons["provider.claude"].waitForExistence(timeout: 2)
            }
        }
        XCTAssertTrue(oauth, "a linked account sets up through OAuth")
        assertOpensInAppBrowser(app)
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
