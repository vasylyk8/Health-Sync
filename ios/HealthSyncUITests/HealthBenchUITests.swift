import XCTest

/// Not part of normal CI (see the healthkit-bench workflow): launches the app in its benchmark mode,
/// accepts the Health permission sheet and prints the results as they come in.
final class HealthBenchUITests: XCTestCase {
    func testHealthBench() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        let count = ProcessInfo.processInfo.environment["BENCH_COUNT"] ?? "300"
        let history = ProcessInfo.processInfo.environment["BENCH_HISTORY"] == "1"
        let scheduling = ProcessInfo.processInfo.environment["BENCH_SCHEDULING"] == "1"
        app.launchArguments = ["-healthBench", "-benchCount", count]
        if history { app.launchArguments += ["-benchHistory", "-benchHeavy", "24"] }
        if scheduling && !history { app.launchArguments += ["-benchScheduling", "-benchHeavy", "24"] }
        app.launch()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let output = app.staticTexts["benchOutput"]
        XCTAssertTrue(output.waitForExistence(timeout: 60))
        var printed = 0
        var sheetSteps = 0
        let deadline = Date().addingTimeInterval(TimeInterval(Int(ProcessInfo.processInfo.environment["BENCH_MINUTES"] ?? "60") ?? 60) * 60)
        while Date() < deadline {
            // The Health permission sheet: "Turn On All", then "Allow".
            for host in [app, springboard] {
                for name in ["Turn On All", "Allow", "Done"] where sheetSteps < 6 {
                    let button = host.buttons[name]
                    let cell = host.staticTexts[name]
                    if button.exists && button.isHittable { button.tap(); sheetSteps += 1; print("BENCHUI tapped \(name)"); break }
                    if name == "Turn On All", cell.exists, cell.isHittable { cell.tap(); sheetSteps += 1; print("BENCHUI tapped text \(name)"); break }
                }
            }
            let text = output.label
            let lines = text.components(separatedBy: "\n")
            if lines.count > printed {
                lines[printed...].forEach { print("BENCHLOG " + $0) }
                printed = lines.count
            }
            if text.contains("BENCH DONE") { break }
            if printed <= 3 && sheetSteps == 0 { print("BENCHUI waiting; tree:\n" + app.debugDescription.prefix(1500)) }
            Thread.sleep(forTimeInterval: 3)
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(output.label.contains("BENCH DONE"), "benchmark did not finish")
        if history {
            XCTAssertTrue(output.label.contains("HIST CHECK OK"), "history experiment changed data or failed: " + output.label)
            XCTAssertTrue(output.label.contains(", 0 failures,"), "workout seed must complete without errors")
            XCTAssertFalse(output.label.contains("HIST seed failed"))
            XCTAssertFalse(output.label.contains("background save error"))
        }
        if scheduling && !history { XCTAssertTrue(output.label.contains("SCHED CHECK OK"), "scheduling changed data or failed: " + output.label) }
    }
}
