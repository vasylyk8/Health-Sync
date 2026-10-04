import XCTest

/// Not part of normal CI (see the daily-check workflow): launches the app in its daily-check mode, which writes a few days
/// of readings into the simulator's HealthKit and checks that the app's daily pass reads every metric back.
final class DailyCheckUITests: XCTestCase {
    func testDailyMetricsComeOut() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-healthBench", "-dailyCheck"]
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let output = app.staticTexts["benchOutput"]
        XCTAssertTrue(output.waitForExistence(timeout: 60))
        var printed = 0
        var sheetSteps = 0
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            for host in [app, springboard] {
                for name in ["Turn On All", "Allow", "Done"] where sheetSteps < 6 {
                    let button = host.buttons[name]
                    let cell = host.staticTexts[name]
                    if button.exists && button.isHittable { button.tap(); sheetSteps += 1; print("DAILYUI tapped \(name)"); break }
                    if name == "Turn On All", cell.exists, cell.isHittable { cell.tap(); sheetSteps += 1; print("DAILYUI tapped text \(name)"); break }
                }
            }
            let text = output.label
            let lines = text.components(separatedBy: "\n")
            if lines.count > printed {
                lines[printed...].forEach { print("DAILYLOG " + $0) }
                printed = lines.count
            }
            if text.contains("BENCH DONE") { break }
            Thread.sleep(forTimeInterval: 3)
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(output.label.contains("BENCH DONE"), "the check did not finish")
        XCTAssertTrue(output.label.contains("DAILYCHECK history done"), "the multi-year sync did not finish: " + output.label.components(separatedBy: "\n").filter { $0.contains("history") }.joined(separator: " | "))
        XCTAssertFalse(output.label.contains("DAILYCHECK FAIL history"), "multi-year sync: " + output.label.components(separatedBy: "\n").filter { $0.contains("FAIL history") }.joined(separator: " | "))
        XCTAssertTrue(output.label.contains("DAILYCHECK OK"), "daily metrics missing: " + output.label.components(separatedBy: "\n").filter { $0.contains("DAILYCHECK") }.joined(separator: " | "))
        XCTAssertTrue(output.label.contains("DAILYSEM OK"), "raw aggregation vs HealthKit statistics: " + output.label.components(separatedBy: "\n").filter { $0.contains("DAILYSEM") }.joined(separator: " | "))
        XCTAssertTrue(output.label.contains("DAILYRAW OK"), "daily pass without statistics: " + output.label.components(separatedBy: "\n").filter { $0.contains("DAILYRAW") }.joined(separator: " | "))
    }
}
