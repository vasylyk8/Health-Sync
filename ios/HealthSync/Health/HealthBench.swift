#if DEBUG
import CoreLocation
import HealthKit
import SwiftUI
import os

/// Test harness (debug builds only, launched by CI with `-healthBench`): fills the simulator's HealthKit
/// with synthetic workouts, then times reading them back the same way the app does. Never part of a release.
@MainActor
final class BenchModel: ObservableObject {
    @Published var text = "BENCH starting"
    var speed = ""
    var engineOutcome: String?
    private static let logger = Logger(subsystem: "app.healthsync", category: "bench")
    func log(_ s: String) {
        text += "\n" + s
        print("BENCH " + s)
        Self.logger.notice("BENCH \(s, privacy: .public)")
    }
}

struct BenchView: View {
    @StateObject private var model = BenchModel()
    var body: some View {
        ScrollView {
            Text(model.text)
                .font(.system(size: 9, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("benchOutput")
        }
        .task { await HealthBench.run(model) }
    }
}

@MainActor
enum HealthBench {
    /// Logs when the main thread stops answering (a blocked main thread also stops the bench's own checks).
    private static func startMainThreadWatchdog() {
        let logger = Logger(subsystem: "app.healthsync", category: "bench")
        final class Beat: @unchecked Sendable {
            let lock = NSLock()
            var lastSeen = Date()
        }
        let beat = Beat()
        Thread.detachNewThread {
            while true {
                DispatchQueue.main.async { beat.lock.withLock { beat.lastSeen = Date() } }
                Thread.sleep(forTimeInterval: 5)
                let stalled = Date().timeIntervalSince(beat.lock.withLock { beat.lastSeen })
                if stalled > 8 { logger.notice("BENCH main thread blocked for \(Int(stalled), privacy: .public) s") }
                // Engine progress straight from the timing summary, independent of the main thread.
                logger.notice("BENCH tick: \(SyncTiming.shared.startupSummary().replacingOccurrences(of: "\n", with: " | "), privacy: .public)")
            }
        }
    }

    static func run(_ m: BenchModel) async {
        startMainThreadWatchdog()
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-dailyCheck") {
            await DailyCheck.run(m)
            return
        }
        let count = args.firstIndex(of: "-benchCount").flatMap { Int(args[$0 + 1]) } ?? 300
        let store = HKHealthStore()
        let scope = HealthTypes.scope(HealthTypes.loadCoverage())
        let share = HealthLab.shareTypes
        let read = HealthTypes.readPermissions(for: scope).union(share)
        m.log("authorizing")
        // One request only: a second permission request right after a first one never answers in the
        // simulator (no sheet, no callback), which hung earlier runs before the sync started.
        do {
            try await store.requestAuthorization(toShare: share, read: read)
        } catch {
            m.log("authorization failed: \(error)")
            m.log("BENCH DONE")
            return
        }
        m.log("authorized")
        let heavy = args.firstIndex(of: "-benchHeavy").flatMap { Int(args[$0 + 1]) } ?? 60
        let light = max(0, count - heavy)
        await HealthLab.seed(store, heavy: heavy, light: light, m)
        await seedBackground(store, count: 100_000, m)
        if args.contains("-benchLab") { await HealthLab.run(store, scope: scope, m) }
        // The in-app speed test, exactly as on a phone (its rows are logged as they appear).
        let printed = BenchCounter()
        let t0 = Date()
        if !args.contains("-benchSkipSpeedTest") {
        await HealthKitSource(scope: scope).benchmark { text in
            let rows = text.components(separatedBy: "\n").filter { !$0.hasPrefix("Running") }
            let new = Array(rows.dropFirst(printed.take(rows.count)))
            let at = Date().timeIntervalSince(t0)
            Task { @MainActor in
                for row in new { m.log(String(format: "speed test %.0fs: ", at) + row) }
            }
        }
        }
        // Whole sync A/B over a simulated network (per-upload speed, optional limit for all uploads together):
        // A = one raw-data group uploaded at a time (as shipped), B = groups upload while the next are read.
        for (pipelined, rate, cap) in [(false, 0.6, nil), (true, 0.6, nil), (false, 0.2, nil), (true, 0.2, nil),
                                       (false, 0.2, 0.6), (true, 0.2, 0.6), (true, 0.6, nil), (false, 0.6, nil)] as [(Bool, Double, Double?)] {
            var config = SyncEngine.Config()
            config.detailGroupsUploading = pipelined ? 3 : 1
            let net = SimNet(perUploadMBs: rate, capMBs: cap)
            await engineRun(scope, m, label: "\(pipelined ? "B pipelined" : "A one group at a time") · \(rate) MB/s per upload\(cap.map { ", \($0) MB/s total" } ?? "")", config: config, uploader: net)
        }
        m.log("BENCH DONE")
    }

    /// Reads every workout the way the app does (per-workout queries, many at once) and reports the rate.
    private static func endToEnd(_ source: HealthKitSource, _ m: BenchModel) async {
        guard let index = try? await source.workoutIndex() else {
            m.log("e2e: could not list workouts")
            return
        }
        for width in [1, 8, 24] {
            source.setQueryConcurrency(width * 2)
            let ids = Array(index.prefix(120))
            var points = 0
            var done = 0
            let t0 = Date()
            await withTaskGroup(of: Int.self) { group in
                var next = 0
                func add() {
                    guard next < ids.count else { return }
                    let id = ids[next].id
                    next += 1
                    group.addTask {
                        let records = try? await source.workoutDetail(id: id, gen: 1)
                        return records?.count ?? 0
                    }
                }
                for _ in 0 ..< width { add() }
                while let c = await group.next() {
                    points += c
                    done += 1
                    add()
                }
            }
            let secs = Date().timeIntervalSince(t0)
            m.log(String(format: "e2e width %d: %d workouts in %.1f s = %.1f workouts/min (%d records)", width, done, secs, Double(done) / secs * 60, points))
        }
    }

    /// The app's whole first sync (steps 1-4) with the real HealthKit reader and an in-memory server,
    /// to catch a step that never finishes. Logs what is running every 15 s; gives up after 10 minutes.
    private static func engineRun(_ scope: SyncScope, _ m: BenchModel, label: String = "", config: SyncEngine.Config = SyncEngine.Config(), uploader: Uploader = FakeBackend()) async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-\(UUID().uuidString)")
        let engine = SyncEngine(source: HealthKitSource(scope: scope), uploader: uploader, outbox: Outbox(root: root), scope: scope, config: config)
        let t0 = Date()
        m.log("engine: first sync starting")
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if Task.isCancelled { break }
                let p = await engine.progress
                m.log("engine \(Int(Date().timeIntervalSince(t0)))s: phase \(p.phase), details \(p.detailsDone)/\(p.detailsTotal) | " + SyncTiming.shared.startupSummary().replacingOccurrences(of: "\n", with: " | "))
            }
        }
        // Polled instead of awaited, so a sync that never finishes is reported instead of hanging the bench.
        m.engineOutcome = nil
        let run = Task { @MainActor in
            let result: String
            do { result = "finished: \(try await engine.run())" } catch { result = "failed: \(error)" }
            m.engineOutcome = result
        }
        var outcome = "TIMEOUT after 300 s (stuck)"
        while Date().timeIntervalSince(t0) < 300 {
            try? await Task.sleep(for: .seconds(1))
            if let done = m.engineOutcome {
                outcome = done
                break
            }
        }
        run.cancel()
        watcher.cancel()
        let p = await engine.progress
        let netInfo = (uploader as? SimNet)?.summary(wall: Date().timeIntervalSince(t0)) ?? ""
        m.log("engine \(label): \(outcome) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s, details \(p.detailsDone)/\(p.detailsTotal) \(netInfo)")
    }

    /// All-day heart rate outside workouts (a watch records it every few minutes), so the database is
    /// much bigger than the workouts alone, as on a real phone. Samples inside workouts are skipped.
    private static func seedBackground(_ store: HKHealthStore, count: Int, _ m: BenchModel) async {
        guard count > 0 else { return }
        let hr = HKQuantityType(.heartRate)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let workouts = await allWorkouts(store)
        let ranges = workouts.map { ($0.startDate, $0.endDate) }
        let t0 = Date()
        var batch: [HKSample] = []
        var saved = 0
        var t = Date().addingTimeInterval(-60)
        for _ in 0 ..< count {
            t = t.addingTimeInterval(-300)
            if ranges.contains(where: { t >= $0.0 && t <= $0.1 }) { continue }
            batch.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: 60 + Double(saved % 40)), start: t, end: t))
            if batch.count == 20_000 {
                do { try await store.save(batch); saved += batch.count } catch { m.log("background save error: \(error)"); return }
                batch = []
            }
        }
        if !batch.isEmpty { try? await store.save(batch); saved += batch.count }
        m.log(String(format: "background heart rate: %d samples in %.0f s", saved, Date().timeIntervalSince(t0)))
    }

    private static func allWorkouts(_ store: HKHealthStore) async -> [HKWorkout] {
        await withCheckedContinuation { c in
            let q = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: nil, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]) { _, r, _ in
                c.resume(returning: (r as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    private struct Lite: Sendable {
        var start: Date
        var end: Date
        var bundle: String
    }

    /// Candidate strategy: read each type's whole history in big pages (a few queries in total) and assign
    /// samples to workouts by time and source, instead of ~3 queries per workout. Checked against the
    /// per-workout (association) query for every workout, and timed against it.
    private static func bulkScan(_ store: HKHealthStore, _ m: BenchModel) async {
        let types = [HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned), HKQuantityType(.distanceWalkingRunning)]
        let workouts = await allWorkouts(store)
        guard !workouts.isEmpty else { return }

        let t0 = Date()
        let perType: [[Lite]] = await withTaskGroup(of: (Int, [Lite]).self) { group in
            for (i, type) in types.enumerated() {
                group.addTask {
                    var out: [Lite] = []
                    var anchor: HKQueryAnchor?
                    while true {
                        let page: ([HKSample], HKQueryAnchor?) = await withCheckedContinuation { c in
                            let q = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: 50_000) { _, samples, _, next, _ in
                                c.resume(returning: (samples ?? [], next))
                            }
                            store.execute(q)
                        }
                        out.append(contentsOf: page.0.map { Lite(start: $0.startDate, end: $0.endDate, bundle: $0.sourceRevision.source.bundleIdentifier) })
                        anchor = page.1
                        if page.0.count < 50_000 { break }
                    }
                    return (i, out)
                }
            }
            var res = [[Lite]](repeating: [], count: types.count)
            for await (i, list) in group { res[i] = list }
            return res
        }
        let scanSecs = Date().timeIntervalSince(t0)
        // Assign each sample to the workout whose time range holds it (workouts sorted by start; binary search).
        let starts = workouts.map(\.startDate)
        var bucket = [[Int]](repeating: [Int](repeating: 0, count: types.count), count: workouts.count)
        var total = 0
        for (ti, list) in perType.enumerated() {
            total += list.count
            for s in list {
                var lo = 0, hi = starts.count - 1, found = -1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    if starts[mid] <= s.start { found = mid; lo = mid + 1 } else { hi = mid - 1 }
                }
                guard found >= 0 else { continue }
                let w = workouts[found]
                if s.start <= w.endDate && s.end <= w.endDate && s.bundle == w.sourceRevision.source.bundleIdentifier {
                    bucket[found][ti] += 1
                }
            }
        }
        let bulkSecs = Date().timeIntervalSince(t0)
        m.log(String(format: "bulk: %d samples of %d types read in %.1f s (%.0f samples/s), assigned in %.1f s total", total, types.count, scanSecs, Double(total) / max(scanSecs, 0.001), bulkSecs))

        // Reference: one association query per workout and type (what the app does now), 24 at a time.
        let t1 = Date()
        let reference: [[Int]] = await withTaskGroup(of: (Int, Int, Int).self) { group in
            var jobs: [(Int, Int)] = []
            for wi in workouts.indices { for ti in types.indices { jobs.append((wi, ti)) } }
            var next = 0
            func add() {
                guard next < jobs.count else { return }
                let (wi, ti) = jobs[next]
                next += 1
                let w = workouts[wi], type = types[ti]
                group.addTask {
                    let n: Int = await withCheckedContinuation { c in
                        let q = HKSampleQuery(sampleType: type, predicate: HKQuery.predicateForObjects(from: w), limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, r, _ in
                            c.resume(returning: r?.count ?? 0)
                        }
                        store.execute(q)
                    }
                    return (wi, ti, n)
                }
            }
            for _ in 0 ..< 24 { add() }
            var res = [[Int]](repeating: [Int](repeating: 0, count: types.count), count: workouts.count)
            while let (wi, ti, n) = await group.next() {
                res[wi][ti] = n
                add()
            }
            return res
        }
        let refSecs = Date().timeIntervalSince(t1)
        var mismatched = 0
        var refTotal = 0
        for wi in workouts.indices {
            refTotal += reference[wi].reduce(0, +)
            if reference[wi] != bucket[wi] { mismatched += 1 }
        }
        m.log(String(format: "per-workout queries: %d samples in %.1f s (%.0f workouts/min)", refTotal, refSecs, Double(workouts.count) / max(refSecs, 0.001) * 60))
        m.log(String(format: "bulk vs per-workout: %.1fx faster, %d of %d workouts differ", refSecs / max(bulkSecs, 0.001), mismatched, workouts.count))
    }

    private static func seed(_ store: HKHealthStore, count: Int, _ m: BenchModel) async {
        let hr = HKQuantityType(.heartRate)
        let energy = HKQuantityType(.activeEnergyBurned)
        let distance = HKQuantityType(.distanceWalkingRunning)
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let t0 = Date()
        var samplesTotal = 0
        var failures = 0
        m.log("seeding \(count) workouts")
        for i in 0 ..< count {
            let dur = 1800 + Double(i % 7) * 600
            // One workout every ~10 days going back, so the history spans years like a real one.
            let start = Date().addingTimeInterval(-Double(i + 1) * 864_000 * 0.9 - 7200)
            let config = HKWorkoutConfiguration()
            config.activityType = i % 3 == 0 ? .cycling : .running
            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
            do {
                try await builder.beginCollection(at: start)
                var samples: [HKSample] = []
                var t = 0.0
                while t < dur {
                    let v = 125 + 30 * sin(t / 300 + Double(i))
                    samples.append(HKQuantitySample(type: hr, quantity: HKQuantity(unit: bpm, doubleValue: v), start: start.addingTimeInterval(t), end: start.addingTimeInterval(t)))
                    t += 3
                }
                t = 0
                while t + 10 <= dur {
                    let s = start.addingTimeInterval(t), e = start.addingTimeInterval(t + 10)
                    samples.append(HKQuantitySample(type: energy, quantity: HKQuantity(unit: .kilocalorie(), doubleValue: 0.4), start: s, end: e))
                    samples.append(HKQuantitySample(type: distance, quantity: HKQuantity(unit: .meter(), doubleValue: 28), start: s, end: e))
                    t += 10
                }
                try await builder.addSamples(samples)
                try await builder.endCollection(at: start.addingTimeInterval(dur))
                guard let workout = try await builder.finishWorkout() else { failures += 1; continue }
                samplesTotal += samples.count
                if i % 2 == 0 {
                    let route = HKWorkoutRouteBuilder(healthStore: store, device: nil)
                    var locs: [CLLocation] = []
                    var r = 0.0
                    while r < dur {
                        locs.append(CLLocation(coordinate: CLLocationCoordinate2D(latitude: 50 + r * 1e-6, longitude: 30 + r * 1e-6), altitude: 100, horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 3, timestamp: start.addingTimeInterval(r)))
                        r += 3
                    }
                    try await route.insertRouteData(locs)
                    _ = try await route.finishRoute(with: workout, metadata: nil)
                }
            } catch {
                failures += 1
                if failures <= 3 { m.log("seed error: \(error)") }
            }
            if (i + 1) % 25 == 0 {
                m.log(String(format: "seeded %d/%d (%.0f s, %d samples, %d failures)", i + 1, count, Date().timeIntervalSince(t0), samplesTotal, failures))
            }
        }
        m.log(String(format: "seed done: %d workouts, %d samples in %.0f s", count - failures, samplesTotal, Date().timeIntervalSince(t0)))
    }
}

/// Simulated network for the sync A/B: each upload takes 0.3 s plus its size at `perUploadMBs`, slowed down
/// when all uploads together would exceed `capMBs`.
final class SimNet: Uploader, @unchecked Sendable {
    private let perUpload: Double
    private let cap: Double?
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var uploads = 0
    private var bytes = 0
    private var busy = 0.0

    init(perUploadMBs: Double, capMBs: Double?) {
        perUpload = perUploadMBs * 1_000_000
        cap = capMBs.map { $0 * 1_000_000 }
    }

    func upload(batchId: String, gz: Data, sha256: String, typeId: String) async throws {
        let t0 = Date()
        lock.withLock {
            active += 1
            peak = max(peak, active)
        }
        defer {
            lock.withLock {
                active -= 1
                uploads += 1
                bytes += gz.count
                busy += Date().timeIntervalSince(t0)
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        var left = Double(gz.count)
        while left > 0 {
            let now = Double(lock.withLock { active })
            let speed = cap.map { min(perUpload, $0 / max(1, now)) } ?? perUpload
            let step = min(left, speed * 0.05)
            try await Task.sleep(for: .milliseconds(Int(step / speed * 1000)))
            left -= step
        }
    }

    func summary(wall: Double) -> String {
        lock.withLock {
            String(format: "· %d uploads, %.1f MB, %.1f in flight on average (peak %d)", uploads, Double(bytes) / 1_000_000, busy / max(wall, 0.001), peak)
        }
    }
}

/// How many speed-test rows were already logged.
private final class BenchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    /// Returns the rows logged so far and records that `total` are now logged.
    func take(_ total: Int) -> Int {
        lock.withLock {
            defer { n = max(n, total) }
            return n
        }
    }
}
#endif
