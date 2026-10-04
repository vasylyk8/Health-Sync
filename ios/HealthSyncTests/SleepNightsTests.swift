import XCTest
@testable import HealthSync

final class SleepNightsTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func d(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2024, month: 6, day: day, hour: hour, minute: minute))!
    }

    private func num(_ v: RecordValue?) -> Double? {
        if case .double(let x)? = v { return x }
        return nil
    }

    func testNightIsDatedByTheMorningItEnds() {
        XCTAssertEqual(SleepNights.nightKey(d(20, 6, 40), calendar: cal), "2024-06-20")
        XCTAssertEqual(SleepNights.nightKey(d(20, 17, 59), calendar: cal), "2024-06-20")
        XCTAssertEqual(SleepNights.nightKey(d(20, 18, 0), calendar: cal), "2024-06-21", "an evening segment belongs to the next night")
        XCTAssertEqual(SleepNights.nightKey(d(20, 13, 30), calendar: cal), "2024-06-20", "a late riser's sleep is not pushed to the next day")
    }

    func testUnionMinutesDoesNotDoubleCountOverlap() {
        XCTAssertEqual(SleepNights.unionMinutes([(d(1, 0), d(1, 1)), (d(1, 0, 30), d(1, 1, 30)), (d(1, 3), d(1, 3, 10))]), 100)
    }

    func testStagesForOneNight() {
        let src = "Apple Watch"
        let segs = [
            SleepSegment(start: d(19, 23), end: d(20, 0, 30), value: SleepNights.core, source: src),
            SleepSegment(start: d(20, 0, 30), end: d(20, 1, 30), value: SleepNights.deep, source: src),
            SleepSegment(start: d(20, 1, 30), end: d(20, 2), value: SleepNights.awake, source: src),
            SleepSegment(start: d(20, 2), end: d(20, 6), value: SleepNights.rem, source: src),
            SleepSegment(start: d(19, 22, 45), end: d(20, 6, 30), value: SleepNights.inBed, source: "iPhone"),
        ]
        let nights = SleepNights.nights(segs, calendar: cal)
        XCTAssertEqual(Array(nights.keys), ["2024-06-20"])
        let m = nights["2024-06-20"]!
        XCTAssertEqual(num(m["sleepCoreMin"]), 90)
        XCTAssertEqual(num(m["sleepDeepMin"]), 60)
        XCTAssertEqual(num(m["sleepRemMin"]), 240)
        XCTAssertEqual(num(m["sleepAwakeMin"]), 30)
        XCTAssertEqual(num(m["sleepAsleepMin"]), 390)
        XCTAssertEqual(num(m["sleepInBedMin"]), 465, "in-bed time comes from the phone")
        XCTAssertEqual(m["sleepBedtime"], .string("22:45"))
        XCTAssertEqual(m["sleepWakeTime"], .string("06:00"))
    }

    func testOverlappingSourcesAreNotDoubleCounted() {
        let segs = [
            SleepSegment(start: d(19, 23), end: d(20, 7), value: SleepNights.unspecified, source: "Sleep app"),
            SleepSegment(start: d(19, 23), end: d(20, 5), value: SleepNights.core, source: "Apple Watch"),
            SleepSegment(start: d(20, 5), end: d(20, 6), value: SleepNights.rem, source: "Apple Watch"),
        ]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(num(m["sleepAsleepMin"]), 420, "only the source with stages counts (7 h, not 15 h)")
    }

    func testNightsWithoutInBedFallBackToTimeAsleepOrAwake() {
        let segs = [SleepSegment(start: d(19, 23), end: d(20, 5), value: SleepNights.unspecified, source: "Watch")]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(num(m["sleepAsleepMin"]), 360)
        XCTAssertEqual(num(m["sleepInBedMin"]), 360)
        XCTAssertNil(m["sleepCoreMin"], "no stages recorded")
    }

    /// A real night (May 11, 2026): sleep the evening before, then an afternoon nap, no in-bed record. In bed showed
    /// 1,439 min (first segment to last).
    func testNapsDoNotStretchTimeInBed() {
        let w = "Apple Watch"
        let segs = [
            SleepSegment(start: d(19, 18, 30), end: d(19, 20), value: SleepNights.core, source: w),
            SleepSegment(start: d(19, 23), end: d(20, 3), value: SleepNights.core, source: w),
            SleepSegment(start: d(20, 3), end: d(20, 3, 10), value: SleepNights.awake, source: w),
            SleepSegment(start: d(20, 3, 10), end: d(20, 7), value: SleepNights.rem, source: w),
            SleepSegment(start: d(20, 15), end: d(20, 16), value: SleepNights.core, source: w),
        ]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(num(m["sleepAsleepMin"]), 90 + 240 + 230 + 60, "naps still count as time asleep")
        XCTAssertEqual(num(m["sleepInBedMin"]), 90 + 480 + 60)
        XCTAssertEqual(m["sleepBedtime"], .string("23:00"))
        XCTAssertEqual(m["sleepWakeTime"], .string("07:00"))
    }
    func testLongAwakeningDoesNotSplitTheMainNightAndAfternoonNapDoesNotMoveWake() {
        let w = "Watch"
        let segs = [
            SleepSegment(start: d(19, 23), end: d(20, 1), value: SleepNights.core, source: w),
            SleepSegment(start: d(20, 3, 30), end: d(20, 7), value: SleepNights.rem, source: w),
            SleepSegment(start: d(20, 15), end: d(20, 16), value: SleepNights.core, source: w),
            SleepSegment(start: d(19, 19), end: d(19, 19, 1), value: SleepNights.inBed, source: "old phone"),
        ]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(m["sleepBedtime"], .string("23:00"))
        XCTAssertEqual(m["sleepWakeTime"], .string("07:00"))
        XCTAssertEqual(num(m["sleepAsleepMin"]), 390)
    }

    func testExplicitAwakeBridgePreservesAnInterruptedNight() {
        let w = "Watch"
        let segs = [
            SleepSegment(start: d(19, 23), end: d(20, 1), value: SleepNights.core, source: w),
            SleepSegment(start: d(20, 1), end: d(20, 5), value: SleepNights.awake, source: w),
            SleepSegment(start: d(20, 5), end: d(20, 7), value: SleepNights.rem, source: w),
        ]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(m["sleepBedtime"], .string("23:00"))
        XCTAssertEqual(m["sleepWakeTime"], .string("07:00"))
        XCTAssertEqual(num(m["sleepAwakeMin"]), 240)
    }

    func testDaytimeOnlySleepStillHasTimes() {
        let segs = [SleepSegment(start: d(20, 13), end: d(20, 15), value: SleepNights.core, source: "Watch")]
        let m = SleepNights.nights(segs, calendar: cal)["2024-06-20"]!
        XCTAssertEqual(m["sleepBedtime"], .string("13:00"))
        XCTAssertEqual(m["sleepWakeTime"], .string("15:00"))
    }

}
