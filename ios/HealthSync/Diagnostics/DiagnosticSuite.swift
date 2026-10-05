import Foundation
import HealthKit

struct DiagnosticVariant: Codable, Sendable, Identifiable {
    var id: String, width = 2, queryLimit = 32, detailWidth = 24, uploadWidth = 6, groups = 3, batchSize = 48, chunkMonths = 12
    var strategy = "baseline", replay = false, serial = false
    static func plan(deep: Bool) -> [Self] {
        var a = [Self(id: "baseline-start"), Self(id: "serial-daily", width: 1), Self(id: "four-daily", width: 4), Self(id: "fixed-input-pipeline", replay: true), Self(id: "fixed-input-small-batches", uploadWidth: 2, groups: 1, batchSize: 24, replay: true)]
        if deep {
            a += [Self(id: "eight-daily", width: 8), Self(id: "eight-queries", queryLimit: 8), Self(id: "sixteen-queries", queryLimit: 16), Self(id: "sixty-four-queries", queryLimit: 64), Self(id: "twelve-workouts", detailWidth: 12), Self(id: "forty-eight-workouts", detailWidth: 48), Self(id: "serial-phases", serial: true), Self(id: "selective-fallback", strategy: "selectiveFallback"), Self(id: "shared-statistics", strategy: "sharedStatistics"), Self(id: "wider-windows-known-regression", strategy: "widerStatistics"), Self(id: "combined-known-regression", strategy: "combined"), Self(id: "six-month-windows", chunkMonths: 6), Self(id: "fixed-input-large-batches", batchSize: 96, replay: true)]
        }
        a.append(Self(id: "baseline-end")); return a
    }
}

enum DiagnosticSuite {
    struct Options: Sendable {
        var deep = false, delay = 2.0, cutoff = Calendar.current.startOfDay(for: Date())
        var resume: DiagnosticRunReport?, variants: [DiagnosticVariant]?
        var keepCaptures = false
    }
    static func run(scope: SyncScope, categories: Set<String>, options: Options,
                    sourceFactory: @escaping @Sendable () -> any HealthSource,
                    realUploader: (any Uploader)? = nil,
                    onUpdate: @escaping @Sendable (DiagnosticRunReport) -> Void) async throws -> DiagnosticRunReport {
        let reports = DiagnosticReportStore()
        var report = options.resume ?? DiagnosticRunReport()
        let plan = options.variants ?? DiagnosticVariant.plan(deep: options.deep)
        if options.resume == nil {
            report.preset = options.deep ? "Deep investigation" : "Full initial-sync diagnosis"; report.cutoff = options.cutoff
            report.coverage = DiagnosticCoverage.inventory(scope, categories: categories)
            report.configuration = ["uploadModel": "\(options.delay)s per batch", "categories": categories.sorted().joined(separator: ","), "variants": plan.map(\.id).joined(separator: ","), "keepCaptures": String(options.keepCaptures)]
            report.text = "\(report.preset)\n\(plan.count) full-history cases, fixed cutoff \(SleepNights.dayKey(report.cutoff, calendar: .current)). Every enabled metric is included.\nLocal uploads modeled at \(options.delay)s per batch. Phases overlap. Fresh app caches; Apple cache cannot be reset.\n"
        }
        let root = reports.root.appendingPathComponent(report.id + "-private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let baselineRoot = root.appendingPathComponent("baseline-start")
        var reference: DiagnosticRecordIndex?
        if report.cases.contains(where: { $0.name == "baseline-start" }) { reference = try DiagnosticRecordIndex(sink: DiagnosticBatchSink(root: baselineRoot.appendingPathComponent("batches"), delay: 0)) }
        report.status = "running"
        defer { if report.status == "complete" && !options.keepCaptures { try? FileManager.default.removeItem(at: root) } }
        do {
            for variant in plan where !report.cases.contains(where: { $0.name == variant.id }) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.thermalState != .critical else { throw DiagnosticFailure.thermalPause }
                let runRoot = root.appendingPathComponent(variant.id)
                if FileManager.default.fileExists(atPath: runRoot.path) { try FileManager.default.removeItem(at: runRoot) }
                let scratch = try DiagnosticScratch(root: runRoot.appendingPathComponent("inputs"))
                let sourceStore = SourceReplayStore(scratch: variant.replay ? try DiagnosticScratch(root: baselineRoot.appendingPathComponent("inputs")) : scratch)
                let raw = RawReplayStore(scratch: scratch)
                let source = DiagnosticSource(base: sourceFactory(), store: sourceStore, replay: variant.replay)
                let sink = try DiagnosticBatchSink(root: runRoot.appendingPathComponent("batches"), delay: options.delay)
                let box = Outbox(root: runRoot.appendingPathComponent("outbox"))
                let probe = SyncProbeRecorder()
                var config = SyncEngine.Config(); config.detailReadConcurrency = variant.detailWidth; config.uploadConcurrency = variant.uploadWidth; config.detailGroupsUploading = variant.groups; config.detailGroupSize = variant.batchSize
                config.diagnosticSerialPhases = variant.serial; config.diagnosticChunkMonths = variant.chunkMonths
                let savedCutoff = report.cutoff
                let engine = SyncEngine(source: source, uploader: sink, outbox: box, scope: scope, config: config, now: { savedCutoff }, categories: { categories })
                let saved = report
                await engine.onProgress { p in var live = saved; live.text += "\nCase \(saved.cases.count + 1)/\(plan.count): \(variant.id) · \(p.detailsDone)/\(p.detailsTotal) workouts\n" + probe.summary(); onUpdate(live) }
                let sampling = Task { @MainActor in
                    while !Task.isCancelled { probe.sampleDevice(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
                }
                let start = ProcessInfo.processInfo.systemUptime
                let outcome: SyncEngine.Outcome
                do {
                    outcome = try await SyncProbe.$recorder.withValue(probe) {
                        try await SyncProbe.$rawCapture.withValue(variant.replay ? nil : raw) {
                            try await PhoneSyncComparisonContext.$width.withValue(variant.width) {
                                try await PhoneSyncComparisonContext.$queryLimit.withValue(variant.queryLimit) {
                                    try await PhoneSyncComparisonContext.$cutoff.withValue(saved.cutoff) {
                                        try await InitialSyncExperiments.$strategy.withValue(InitialSyncExperiments.Strategy(rawValue: variant.strategy)) {
                                            try await InitialSyncExperiments.$historyStart.withValue(try await source.earliestDailyDate()) {
                                                try await InitialSyncExperiments.$historyEnd.withValue(saved.cutoff) {
                                                    try await SyncTiming.$diagnostic.withValue(SyncTiming(persistEnabled: false)) { try await engine.run() }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } catch { sampling.cancel(); await sampling.value; throw error }
                let wall = ProcessInfo.processInfo.systemUptime - start
                sampling.cancel(); await sampling.value
                let index = try DiagnosticRecordIndex(sink: sink)
                let comparison = try reference.map { try index.compare(to: $0) }
                let complete = outcome == .finished && box.pending().isEmpty && box.state.detailsDone.count == box.state.workoutTotal && box.state.dailyFullAt == saved.cutoff && (scope.hourly.isEmpty || box.state.hourlyAt == saved.cutoff)
                var verdict = !complete ? "INCOMPLETE" : comparison?.equivalent == false ? (variant.replay ? "REPLAY REGRESSION" : "LIVE OUTPUT DIFFERENCE — source/reader investigation required") : "OUTPUT MATCHED in this run; personal accuracy not independently certified"
                let snapshot = probe.snapshot()
                if snapshot.devices.contains(where: { $0.thermal >= 2 }) { verdict += "; heat affected" }
                report.cases.append(DiagnosticCaseReport(name: variant.id, transfer: "local simulated", elapsed: wall, records: index.count, complete: complete, verdict: verdict, changed: comparison?.changedRecords ?? 0, maximumDelta: comparison?.maximumDelta ?? 0, fields: comparison?.changedFields ?? [:], snapshot: snapshot))
                report.text += String(format: "\n%@: %.2fs elapsed · %d records · %@\n", variant.id, wall, index.count, verdict) + probe.summary() + "\n"
                if let comparison { report.text += "Changed fields: \(comparison.changedFields) · max delta \(comparison.maximumDelta)\n" }
                if variant.id == "baseline-start" {
                    reference = index
                    updateCoverage(&report.coverage, sink: sink)
                    report.text += "\nRaw replay: \(raw.inventory.count) captured metric/windows.\n"
                    for f in raw.inventory {
                        try Task.checkCancellation()
                        let a = try raw.replay(f, unified: false), b = try raw.replay(f, unified: true)
                        let same = rawEqual(a, b)
                        report.text += "Raw aggregate replay \(HealthTypes.shortName(f.type)): \(same ? "MATCH" : "DIFFER") · \(f.count) readings\n"
                        if options.deep && f.count <= 10_000 {
                            let reverse = try raw.replay(f, unified: false, reverse: true)
                            if !rawEqual(a, reverse) { report.text += "ORDER-SENSITIVE aggregate: \(HealthTypes.shortName(f.type))\n" }
                        }
                    }
                }
                // A selected real probe uses already-prepared private batches, never the production outbox.
                if variant.id == "baseline-start", let realUploader {
                    let t = ProcessInfo.processInfo.systemUptime
                    for (type, file) in sink.batches {
                        try Task.checkCancellation(); let data = try Data(contentsOf: file)
                        try await realUploader.upload(batchId: UUID().uuidString.lowercased(), gz: data, sha256: DiagnosticScratch.digest(data), typeId: type)
                    }
                    report.text += "Isolated real transfer/readback: \(String(format: "%.2f", ProcessInfo.processInfo.systemUptime - t))s. This transfer runs after preparation, not an end-to-end pipelined upload.\n"
                }
                try reports.save(report); onUpdate(report)
                if variant.id != "baseline-start" { try FileManager.default.removeItem(at: runRoot) }
            }
            report.status = "complete"
            report.text += "\nCoverage: \(report.coverage.filter(\.enabled).count) enabled entries. See JSON for each metric.\nComplete. Faster candidates require repeated stable live runs; lower query counts alone do not qualify.\n"
            try reports.save(report); onUpdate(report); return report
        } catch {
            report.status = "paused"
            report.text += "\nPaused: \((error as NSError).domain) \((error as NSError).code). Completed cases saved. Resume starts an interrupted case from the beginning; history may have changed.\n"
            try reports.save(report); onUpdate(report); throw error
        }
    }
    static func rawEqual(_ a: RawHistorySummary, _ b: RawHistorySummary) -> Bool {
        guard Set(a.daily.keys) == Set(b.daily.keys), a.hourly.count == b.hourly.count else { return false }
        for key in a.daily.keys { let x = a.daily[key]!, y = b.daily[key]!; if x.count != y.count { return false }; for (u, v) in zip(x, y) { if u.0 != v.0 || abs(u.1 - v.1) > 1e-9 { return false } } }
        for (u, v) in zip(a.hourly, b.hourly) { if u.t != v.t || !equalOptional(u.v, v.v) || u.lo != v.lo || u.hi != v.hi { return false } }
        return true
    }
    private static func equalOptional(_ a: Double?, _ b: Double?) -> Bool { switch (a, b) { case (nil, nil): return true; case let (a?, b?): return abs(a - b) <= 1e-9; default: return false } }
    private static func updateCoverage(_ rows: inout [DiagnosticCoverage], sink: DiagnosticBatchSink) {
        for (_, file) in sink.batches {
            guard let data = try? Data(contentsOf: file), let bytes = Gzip.decompress(data) else { continue }
            for line in bytes.split(separator: 10).dropFirst() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let q = obj["m"] as? [String: Any] { for key in q.keys { for i in rows.indices where rows[i].metric == key { rows[i].records += 1 } } }
                if let ty = (obj["ty"] ?? obj["st"]) as? String { for i in rows.indices where rows[i].metric == ty { rows[i].records += 1 } }
            }
        }
        for i in rows.indices where rows[i].enabled { rows[i].status = rows[i].records > 0 ? "readable data" : "no readable data or not represented in returned records" }
    }
    enum DiagnosticFailure: Error { case thermalPause }
}
