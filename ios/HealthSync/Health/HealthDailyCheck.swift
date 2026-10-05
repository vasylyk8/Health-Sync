#if DEBUG
import HealthKit

/// Test harness (debug builds only, launched by CI with `-healthBench -dailyCheck`): writes a few days of ordinary
/// readings into the simulator's HealthKit, reads them back through the app's own daily-metrics code and checks that
/// every metric that has data comes out. This is the end-to-end test of the daily pass against real HealthKit.
@MainActor
enum DailyCheck {
    /// (type, unit, value per reading, cumulative)
    private static let seeds: [(HKQuantityTypeIdentifier, HKUnit, Double, Bool)] = [
        (.stepCount, .count(), 800, true),
        (.activeEnergyBurned, .kilocalorie(), 40, true),
        (.distanceWalkingRunning, .meter(), 600, true),
        (.flightsClimbed, .count(), 4, true),
        (.restingHeartRate, HKUnit.count().unitDivided(by: .minute()), 54, false),
        (.heartRateVariabilitySDNN, .secondUnit(with: .milli), 62, false),
        (.respiratoryRate, HKUnit.count().unitDivided(by: .minute()), 15, false),
        (.oxygenSaturation, .percent(), 0.97, false),
        (.vo2Max, HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute())), 48, false),
        (.walkingSpeed, HKUnit.meter().unitDivided(by: .second()), 1.3, false),
        (.environmentalAudioExposure, .decibelAWeightedSoundPressureLevel(), 70, false),
        (.bodyMass, .gramUnit(with: .kilo), 75, false),
    ]

    /// Writes the upload batches the sync engine would send for these days (same code: record builder, header, gzip) to the
    /// log as `DAILYBATCH <id> <n> <base64 piece>` lines. The workflow's server job ingests them and asks questions through
    /// the MCP endpoint, which links what the phone sends to what an AI gets back.
    private static func dumpBatches(_ m: BenchModel, source: HealthKitSource, from start: Date) async {
        let end = Date()
        do {
            let batches = try await source.dailyContextBatches(from: start, to: end, categories: ["nutrition", "mind", "cycle"])
            for batch in batches where !batch.records.isEmpty {
                let header = BatchHeader(type: batch.typeId, mode: .stats, seq: Outbox.seqFloor(), window: (start, end), checkedAt: end)
                let made = try BatchWriter.make(header: header, records: batch.records, nextSeq: { Outbox.seqFloor() + 1 }, tz: TimeZone.current.identifier, device: "daily-check", appVersion: "ci")
                for b in made { emitBatch(m, id: b.id, gz: b.gz) }
            }
        } catch {
            m.log("DAILYCHECK FAIL could not build the upload batches: \(error)")
        }
    }

    /// One batch as `DAILYBATCH <id> <n> <base64 piece>` log lines (the workflow reassembles the files).
    private static func emitBatch(_ m: BenchModel, id: String, gz: Data) {
        let text = gz.base64EncodedString()
        var index = text.startIndex
        var piece = 0
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 180, limitedBy: text.endIndex) ?? text.endIndex
            m.log("DAILYBATCH \(id) \(piece) \(text[index ..< next])")
            index = next
            piece += 1
        }
    }

    /// The whole sync engine (the code that runs on a phone: yearly chunks, hashes, retries, hourly history) over about two
    /// years of ordinary readings, with the uploads captured instead of sent. The daily and hourly batches it produced are
    /// dumped, so the server job can check every day of every year against what was written.
    private static func runHistory(_ m: BenchModel, store: HKHealthStore, scope: SyncScope, today: Date, calendar cal: Calendar) async {
        let days = 800
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double, day: Date, hour: Int) {
            let start = cal.date(byAdding: .hour, value: hour, to: day)!
            samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value), start: start, end: start.addingTimeInterval(1800)))
        }
        // Days 1 to 10 were seeded above; these are the older ones.
        for d in 11 ... days {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            add(.stepCount, .count(), Double(5000 + d), day: day, hour: 12)
            add(.restingHeartRate, bpm, Double(50 + d % 10), day: day, hour: 9)
            add(.heartRateVariabilitySDNN, .secondUnit(with: .milli), Double(40 + d % 20), day: day, hour: 10)
            add(.activeEnergyBurned, .kilocalorie(), Double(300 + d % 50), day: day, hour: 18)
            let bed = cal.date(byAdding: .hour, value: -1, to: day)!
            samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: bed, end: bed.addingTimeInterval(7 * 3600)))
        }
        do {
            var i = 0
            while i < samples.count {
                try await store.save(Array(samples[i ..< min(i + 1000, samples.count)]))
                i += 1000
            }
            m.log("DAILYCHECK history: seeded \(samples.count) readings over \(days) days")
        } catch {
            m.log("DAILYCHECK FAIL history: could not save readings: \(error)")
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dailycheck-\(UUID().uuidString)")
        let uploader = CaptureUploader()
        // Every statistics query failing (the restored iPhone's statistics came back empty, or with an error, for past years):
        // every day and hour the server job checks then comes from the raw-reading fill.
        let source = HealthKitSource(scope: scope)
        source.debugFailingStatistics = true
        let engine = SyncEngine(source: source, uploader: uploader, outbox: Outbox(root: root), scope: scope, categories: { ["core"] })
        let started = Date()
        do {
            _ = try await engine.run()
        } catch {
            m.log("DAILYCHECK FAIL history: the sync threw: \(error)")
        }
        let all = uploader.all
        let kinds = Dictionary(grouping: all, by: \.typeId).map { "\($0.key)x\($0.value.count)" }.sorted().joined(separator: ",")
        m.log("DAILYCHECK history: \(all.count) batches in \(Int(Date().timeIntervalSince(started))) s (\(kinds))")
        for b in all where b.typeId.hasPrefix("_daily") || b.typeId == "_hourly" { emitBatch(m, id: b.id, gz: b.gz) }
        m.log("DAILYCHECK history done")
    }

    /// HealthKit's own statistics and the raw-reading aggregation must agree value for value, including the cases where the
    /// rules matter: a reading that crosses midnight, a heart-rate series reading next to single readings, cumulative readings
    /// across hour and day boundaries, two body-mass readings on one day. Written about 825 days back, outside the days the
    /// other checks look at.
    private static func checkSemantics(_ m: BenchModel, store: HKHealthStore, scope: SyncScope, today: Date, calendar cal: Calendar) async {
        let day = cal.date(byAdding: .day, value: -825, to: today)!
        let bpm = HKUnit.count().unitDivided(by: .minute())
        func at(_ hour: Double, _ base: Date) -> Date { base.addingTimeInterval(hour * 3600) }
        func q(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ v: Double, _ start: Date, _ end: Date) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v), start: start, end: end)
        }
        let before = cal.date(byAdding: .day, value: -1, to: day)!
        let samples: [HKSample] = [
            // The only respiratory-rate reading in these days, from 22:00 to 02:00: which day(s) does HealthKit count it on?
            q(.respiratoryRate, bpm, 14, at(22, before), at(2, day)),
            // Steps from 23:30 to 00:30 and from 14:45 to 15:15: spread over the days and hours by time.
            q(.stepCount, .count(), 600, at(23.5, before), at(0.5, day)),
            q(.stepCount, .count(), 120, at(14.75, day), at(15.25, day)),
            // Two single heart-rate readings next to the series written below.
            q(.heartRate, bpm, 60, at(8, day), at(8, day)),
            q(.heartRate, bpm, 70, at(20, day), at(20, day)),
            // Two weigh-ins: the day's value is the later one.
            q(.bodyMass, .gramUnit(with: .kilo), 80, at(7, day), at(7, day)),
            q(.bodyMass, .gramUnit(with: .kilo), 81, at(19, day), at(19, day)),
        ]
        do {
            try await store.save(samples)
            // A heart-rate series reading (as a workout records it): ten values, 100 to 190.
            let builder = HKQuantitySeriesSampleBuilder(healthStore: store, quantityType: HKQuantityType(.heartRate), startDate: at(12, day), device: nil)
            for i in 0 ..< 10 {
                try builder.insert(HKQuantity(unit: bpm, doubleValue: Double(100 + 10 * i)), at: at(12, day).addingTimeInterval(Double(i) * 10))
            }
            _ = try await builder.finishSeries(metadata: nil, endDate: at(12, day).addingTimeInterval(100))
        } catch {
            m.log("DAILYSEM FAIL could not save readings: \(error)")
            return
        }
        guard await seedShapes(m, store: store, today: today, calendar: cal) else { return }
        let comparisonEnd = Date()
        let cases = RawHistoryExperiment.allCases.map { ($0.rawValue, $0, scope) }
            + HourlyHistoryExperiment.allCases.filter { $0 != .all }.map { ("hourly-" + $0.rawValue, RawHistoryExperiment.baseline, $0.scope(from: scope)) }
        for (name, experiment, candidateScope) in cases {
            let source = HealthKitSource(scope: candidateScope)
            source.historyExperiment = experiment
            do {
                var differences: [String] = []
                var compared = 0
                let shapes = cal.date(byAdding: .day, value: -900, to: today)!
                for (from, to) in [(before, cal.date(byAdding: .day, value: 2, to: day)!), (shapes, cal.date(byAdding: .day, value: 100, to: shapes)!),
                                   (cal.date(byAdding: .day, value: -11, to: today)!, comparisonEnd)] {
                    let r = try await source.statisticsVersusRaw(from: from, to: to)
                    compared += r.compared
                    differences += r.differences
                }
                m.log("DAILYSEM compared \(compared) days and hours, \(differences.count) differ")
                for d in differences.prefix(40) { m.log("DAILYSEM DIFF \(d)") }
                m.log(differences.isEmpty && compared > 0 ? "DAILYSEM OK \(name)" : "DAILYSEM FAIL \(name) raw aggregation differs from HealthKit's statistics")
            } catch {
                m.log("DAILYSEM FAIL \(name) comparison threw: \(error)")
            }
        }
    }

    /// Reading shapes whose daily values depend on HealthKit's rules: heart-rate readings with and without a duration and
    /// series readings of several spacings (time-weighted average), readings that cross midnight by different amounts,
    /// sound levels of different durations. One shape per day (or pair of days), about 900 days back.
    private static func seedShapes(_ m: BenchModel, store: HKHealthStore, today: Date, calendar cal: Calendar) async -> Bool {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let first = cal.date(byAdding: .day, value: -900, to: today)!
        func day(_ i: Int) -> Date { cal.date(byAdding: .day, value: i, to: first)! }
        func hr(_ v: Double, _ start: Date, _ seconds: Double = 0) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: bpm, doubleValue: v), start: start, end: start.addingTimeInterval(seconds))
        }
        func series(_ values: [Double], at start: Date, every step: Double, end: Double) async throws {
            let b = HKQuantitySeriesSampleBuilder(healthStore: store, quantityType: HKQuantityType(.heartRate), startDate: start, device: nil)
            for (i, v) in values.enumerated() { try b.insert(HKQuantity(unit: bpm, doubleValue: v), at: start.addingTimeInterval(Double(i) * step)) }
            _ = try await b.finishSeries(metadata: nil, endDate: start.addingTimeInterval(end))
        }
        func q(_ id: HKQuantityTypeIdentifier, _ v: Double, _ start: Date, _ end: Date, _ unit: HKUnit = HKUnit.count().unitDivided(by: .minute())) -> HKQuantitySample {
            HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v), start: start, end: end)
        }
        func t(_ d: Int, _ hours: Double) -> Date { day(d).addingTimeInterval(hours * 3600) }
        let ten = (0 ..< 10).map { Double(100 + 10 * $0) }
        do {
            // Day 0: single 60 at 08:00 + series of ten (100...190) 10 s apart, 100 s long.
            try await store.save([hr(60, day(0).addingTimeInterval(8 * 3600))])
            try await series(ten, at: day(0).addingTimeInterval(12 * 3600), every: 10, end: 100)
            // Day 1: the same series 1 s apart, 10 s long.
            try await store.save([hr(60, day(1).addingTimeInterval(8 * 3600))])
            try await series(ten, at: day(1).addingTimeInterval(12 * 3600), every: 1, end: 10)
            // Day 2: the same series 60 s apart, 600 s long.
            try await store.save([hr(60, day(2).addingTimeInterval(8 * 3600))])
            try await series(ten, at: day(2).addingTimeInterval(12 * 3600), every: 60, end: 600)
            // Day 3: series of two (100, 190) 10 s apart, 20 s long.
            try await store.save([hr(60, day(3).addingTimeInterval(8 * 3600))])
            try await series([100, 190], at: day(3).addingTimeInterval(12 * 3600), every: 10, end: 20)
            // Day 4: single 60 (instant) + single 100 lasting 100 s.
            try await store.save([hr(60, day(4).addingTimeInterval(8 * 3600)), hr(100, day(4).addingTimeInterval(12 * 3600), 100)])
            // Day 5: single 60 (instant) + single 100 (instant).
            try await store.save([hr(60, day(5).addingTimeInterval(8 * 3600)), hr(100, day(5).addingTimeInterval(12 * 3600))])
            // Day 6: single 60 lasting 60 s + single 100 (instant).
            try await store.save([hr(60, day(6).addingTimeInterval(8 * 3600), 60), hr(100, day(6).addingTimeInterval(12 * 3600))])
            // Day 7: single 60 lasting 600 s + single 100 lasting 60 s.
            try await store.save([hr(60, day(7).addingTimeInterval(8 * 3600), 600), hr(100, day(7).addingTimeInterval(12 * 3600), 60)])
            // Days 9-10: a respiratory-rate reading from 23:00 to 05:00, mostly on day 10.
            try await store.save([HKQuantitySample(type: HKQuantityType(.respiratoryRate), quantity: HKQuantity(unit: bpm, doubleValue: 16),
                                                   start: day(9).addingTimeInterval(23 * 3600), end: day(10).addingTimeInterval(5 * 3600))])
            // Days 12-13: a resting-heart-rate reading from 23:55 to 23:50 the next day (as the Watch writes them).
            try await store.save([HKQuantitySample(type: HKQuantityType(.restingHeartRate), quantity: HKQuantity(unit: bpm, doubleValue: 50),
                                                   start: day(12).addingTimeInterval(23 * 3600 + 55 * 60), end: day(13).addingTimeInterval(23 * 3600 + 50 * 60))])
            // Readings that reach into the next day by 20 h, 8 h, 13 h and 11 h.
            try await store.save([q(.respiratoryRate, 15, t(15, 20), t(16, 20)), q(.restingHeartRate, 55, t(18, 18), t(19, 8)),
                                  q(.respiratoryRate, 17, t(21, 12), t(22, 13)), q(.respiratoryRate, 18, t(24, 13), t(25, 11))])
            // Day 27: sound levels of 60 dB for 30 min and 90 dB for 1 min.
            try await store.save([q(.environmentalAudioExposure, 60, t(27, 9), t(27, 9.5), .decibelAWeightedSoundPressureLevel()),
                                  q(.environmentalAudioExposure, 90, t(27, 15), t(27, 15 + 1.0 / 60), .decibelAWeightedSoundPressureLevel())])
            // Cross an exact monthly raw-query boundary and leave enough range for three parallel windows.
            let boundary = cal.date(byAdding: .month, value: 1, to: first)!
            try await store.save([HKQuantitySample(type: HKQuantityType(.stepCount), quantity: HKQuantity(unit: .count(), doubleValue: 600),
                                                   start: boundary.addingTimeInterval(-1800), end: boundary.addingTimeInterval(1800))])
            return true
        } catch {
            m.log("DAILYSEM FAIL could not save the reading shapes: \(error)")
            return false
        }
    }

    /// The same ten days read with every statistics query coming back empty: every metric must still come out on every day,
    /// from the raw readings alone.
    private static func checkWithoutStatistics(_ m: BenchModel, scope: SyncScope, expected: Set<String>, today: Date, calendar cal: Calendar, experiment: RawHistoryExperiment) async {
        let source = HealthKitSource(scope: scope)
        source.historyExperiment = experiment
        source.debugEmptyStatistics = true
        do {
            let records = try await source.dailyContext(from: cal.date(byAdding: .day, value: -11, to: today)!, to: Date())
            var missingDays: [String] = []
            for d in 1 ... 10 {
                let day = SleepNights.dayKey(cal.date(byAdding: .day, value: -d, to: today)!, calendar: cal)
                let row = records.first { $0["day"] == .string(day) }
                let keys: Set<String>
                if case .object(let values)? = row?["m"] { keys = Set(values.keys) } else { keys = [] }
                let absent = expected.subtracting(keys).sorted()
                if !absent.isEmpty { missingDays.append("\(day):\(absent.joined(separator: ","))") }
            }
            m.log("DAILYRAW note: \(source.dailyDiagnosticNote() ?? "-")")
            m.log(missingDays.isEmpty ? "DAILYRAW OK \(experiment.rawValue)" : "DAILYRAW FAIL \(experiment.rawValue) without statistics, missing: \(missingDays.joined(separator: "; "))")
        } catch {
            m.log("DAILYRAW FAIL \(experiment.rawValue) daily pass threw: \(error)")
        }
    }

    /// Partial hourly statistics and a reading starting more than a day before the query: both previously lost data.
    private static func checkCompleteness(_ m: BenchModel, store: HKHealthStore, scope: SyncScope, today: Date, calendar cal: Calendar, experiment: RawHistoryExperiment) async {
        do {
            let hourly = HealthKitSource(scope: scope)
            hourly.historyExperiment = experiment
            hourly.debugPartialHourlyStatistics = true
            let day = cal.date(byAdding: .day, value: -5, to: today)!
            let end = cal.date(byAdding: .day, value: 1, to: day)!
            guard let metric = scope.hourly.first(where: { $0.name == "StepCount" }) else {
                m.log("DAILYCOMPLETE FAIL hourly steps unavailable")
                return
            }
            let buckets = try await hourly.hourlyBuckets(metric, from: day, to: end)
            let total = buckets.compactMap(\.v).reduce(0, +)
            guard buckets.count == 3 && abs(total - 2415) < 1e-6 else {
                m.log("DAILYCOMPLETE FAIL partial hourly statistics: buckets=\(buckets.count) total=\(total)")
                return
            }
            let target = cal.date(byAdding: .day, value: -960, to: today)!
            let start = cal.date(byAdding: .hour, value: -40, to: target)!
            let finish = cal.date(byAdding: .hour, value: 10, to: target)!
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if experiment == .baseline {
                try await store.save(HKQuantitySample(type: HKQuantityType(.restingHeartRate), quantity: HKQuantity(unit: bpm, doubleValue: 51), start: start, end: finish))
            }
            let raw = HealthKitSource(scope: scope)
            raw.historyExperiment = experiment
            raw.debugEmptyStatistics = true
            let to = cal.date(byAdding: .hour, value: 12, to: target)!
            let batches = try await raw.dailyContextBatches(from: target, to: to, categories: [])
            let rows = batches.flatMap(\.records)
            let key = SleepNights.dayKey(target, calendar: cal)
            guard let row = rows.first(where: { $0["day"] == .string(key) }), case .object(let values)? = row["m"],
                  case .double(let resting)? = values["restingHr"], abs(resting - 51) < 1e-6 else {
                m.log("DAILYCOMPLETE FAIL long reading crossing query start")
                return
            }
            for batch in batches where !batch.records.isEmpty {
                let header = BatchHeader(type: batch.typeId, mode: .stats, seq: Outbox.seqFloor(), window: (target, to), checkedAt: Date())
                let made = try BatchWriter.make(header: header, records: batch.records, nextSeq: { Outbox.seqFloor() + 1 }, tz: TimeZone.current.identifier, device: "daily-check", appVersion: "ci")
                for b in made { emitBatch(m, id: b.id, gz: b.gz) }
            }
            m.log("DAILYCOMPLETE OK \(experiment.rawValue) partial hours and long boundary readings")
        } catch {
            m.log("DAILYCOMPLETE FAIL \(error)")
        }
    }

    static func run(_ m: BenchModel) async {
        let store = HKHealthStore()
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        var share: Set<HKSampleType> = [HKCategoryType(.sleepAnalysis), HKQuantityType(.heartRate)]
        for s in seeds { share.insert(HKQuantityType(s.0)) }
        m.log("DAILYCHECK authorizing")
        do {
            try await store.requestAuthorization(toShare: share, read: HealthTypes.readPermissions(for: scope).union(share))
        } catch {
            m.log("DAILYCHECK FAIL authorization failed: \(error)")
            m.log("BENCH DONE")
            return
        }
        // Ten days of readings: cumulative types get three readings a day, the others one.
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var samples: [HKSample] = []
        for d in 1 ... 10 {
            let day = cal.date(byAdding: .day, value: -d, to: today)!
            for (id, unit, value, cumulative) in seeds {
                let hours = cumulative ? [8, 12, 16] : [9]
                for h in hours {
                    let start = cal.date(byAdding: .hour, value: h, to: day)!
                    let q = HKQuantity(unit: unit, doubleValue: value + Double(d))
                    samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: q, start: start, end: start.addingTimeInterval(1800)))
                }
            }
            // The night that ends on this day.
            let bed = cal.date(byAdding: .hour, value: -1, to: day)!
            samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: HKCategoryValueSleepAnalysis.asleepCore.rawValue, start: bed, end: bed.addingTimeInterval(7 * 3600)))
        }
        do {
            try await store.save(samples)
            m.log("DAILYCHECK seeded \(samples.count) readings")
        } catch {
            m.log("DAILYCHECK FAIL could not save readings: \(error)")
            m.log("BENCH DONE")
            return
        }

        // What the app should produce: every core metric whose HealthKit type was seeded, plus sleep.
        let seeded = Set(seeds.map { HKQuantityType($0.0).identifier })
        let coverage = HealthTypes.loadCoverage()
        let expected = Set((coverage?.dailyMetrics ?? []).filter { ($0.category ?? "core") == "core" && seeded.contains($0.id) }.map(\.key)).union(["sleepAsleepMin"])
        let source = HealthKitSource(scope: scope)
        do {
            let records = try await source.dailyContext(from: cal.date(byAdding: .day, value: -11, to: today)!, to: Date())
            var found = Set<String>()
            var rows = 0
            for r in records {
                guard case .object(let metrics)? = r["m"] else { continue }
                rows += 1
                found.formUnion(metrics.keys)
            }
            let missing = expected.subtracting(found).sorted()
            m.log("DAILYCHECK \(rows) day rows; \(expected.subtracting(missing).count) of \(expected.count) expected metrics came out")
            m.log("DAILYCHECK found: \(found.sorted().joined(separator: ", "))")
            m.log("DAILYCHECK report: \(source.dailyReport)")
            var missingDays: [String] = []
            for d in 1 ... 10 {
                let day = SleepNights.dayKey(cal.date(byAdding: .day, value: -d, to: today)!, calendar: cal)
                let row = records.first { $0["day"] == .string(day) }
                let keys: Set<String>
                if case .object(let values)? = row?["m"] { keys = Set(values.keys) } else { keys = [] }
                let absent = expected.subtracting(keys).sorted()
                if !absent.isEmpty { missingDays.append("\(day):\(absent.joined(separator: ","))") }
            }
            let retainedAllResults = source.dailyReport.contains("0 retried.")
            if missing.isEmpty && missingDays.isEmpty && retainedAllResults {
                m.log("DAILYCHECK OK")
            } else {
                m.log("DAILYCHECK FAIL missing: \(missing.joined(separator: ", ")); days: \(missingDays.joined(separator: "; ")); retainedAllResults=\(retainedAllResults)")
            }
        } catch {
            m.log("DAILYCHECK FAIL daily pass threw: \(error) · report: \(source.dailyReport)")
        }
        await checkSemantics(m, store: store, scope: scope, today: today, calendar: cal)
        for experiment in RawHistoryExperiment.allCases {
            await checkWithoutStatistics(m, scope: scope, expected: expected, today: today, calendar: cal, experiment: experiment)
        }
        await dumpBatches(m, source: source, from: cal.date(byAdding: .day, value: -11, to: today)!)
        await runHistory(m, store: store, scope: scope, today: today, calendar: cal)
        for experiment in RawHistoryExperiment.allCases {
            await checkCompleteness(m, store: store, scope: scope, today: today, calendar: cal, experiment: experiment)
        }
        m.log("BENCH DONE")
    }
}

/// An uploader that keeps what the sync engine sends instead of sending it.
private final class CaptureUploader: Uploader, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(id: String, gz: Data, typeId: String)] = []
    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        lock.withLock { items.append((batchId, gz, typeId)) }
    }
    var all: [(id: String, gz: Data, typeId: String)] { lock.withLock { items } }
}
#endif
