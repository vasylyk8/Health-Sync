import XCTest

/// Not part of normal CI (see the daily-check workflow): launches the app in its daily-check mode, which writes a few days
/// of readings into the simulator's HealthKit and checks that the app's daily pass reads every metric back.
final class DailyCheckUITests: XCTestCase {
    func testDailyMetricsComeOut() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-healthBench", "-dailyCheck", "-dailyConcurrency", ProcessInfo.processInfo.environment["DAILY_CONCURRENCY"] ?? "1"]
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
        // Every check is reported at once, so one failing run shows all of them.
        let all = output.label.components(separatedBy: "\n")
        func lines(_ tag: String) -> String { all.filter { $0.contains(tag) && !$0.contains("DAILYBATCH") }.joined(separator: " | ") }
        var failures: [String] = []
        if !output.label.contains("DAILYCHECK history done") { failures.append("the multi-year sync did not finish: " + lines("history")) }
        if output.label.contains("DAILYCHECK FAIL history") { failures.append("multi-year sync: " + lines("FAIL history")) }
        if !output.label.contains("DAILYCHECK OK") { failures.append("daily metrics missing: " + lines("DAILYCHECK")) }
        if !output.label.contains("DAILYSEM OK") { failures.append("raw aggregation vs HealthKit statistics: " + lines("DAILYSEM")) }
        if !output.label.contains("DAILYRAW OK") { failures.append("daily pass without statistics: " + lines("DAILYRAW")) }
        if !output.label.contains("DAILYCOMPLETE OK") { failures.append("partial hours and long samples: " + lines("DAILYCOMPLETE")) }
        if !output.label.contains("DAILYSHARED FRESH OK") { failures.append("later Health imports were not re-read") }
        if output.label.contains("DAILYSHARED FAIL") { failures.append("shared cache was not exercised") }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: " || "))
    }
}
