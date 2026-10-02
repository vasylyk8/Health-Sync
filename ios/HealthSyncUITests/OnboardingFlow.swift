import XCTest

extension XCUIApplication {
    /// Welcome → Connect to Apple Health → account page → (stand-in for Apple's sheet) → Home.
    func signInThroughAccountPage(file: StaticString = #filePath, line: UInt = #line) {
        let apple = buttons["appleSignIn"]
        XCTAssertTrue(apple.waitForExistence(timeout: 10), "account page shows Sign in with Apple", file: file, line: line)
        let stand = buttons["uiTestSignIn"]
        if !stand.isHittable { swipeUp() }
        stand.tap()
    }
}
