import Foundation
import HealthKit

struct DiagnosticVariant: Codable, Sendable, Identifiable {
    var id: String, width = 2, queryLimit = 0, detailWidth = 24, uploadWidth = 6, groups = 3, batchSize = 48, chunkMonths = 12
    var strategy = "baseline", replay = false, serial = false
    var family = "all", includeRoutes = true, routeWidth = 8, shareRouteGate = true
    var historyCapacity = 0, cacheRows = 0
    var fault = "", instrument = true, captureRaw = true
    static func plan(deep: Bool) -> [Self] {
        var a = [Self(id: "baseline-start"), Self(id: "serial-daily", width: 1), Self(id: "four-daily", width: 4), Self(id: "fixed-input-pipeline", replay: true), Self(id: "fixed-input-small-batches", uploadWidth: 2, groups: 1, batchSize: 24, replay: true)]
        if deep {
            a += [Self(id: "eight-daily", width: 8), Self(id: "eight-queries", queryLimit: 8), Self(id: "sixteen-queries", queryLimit: 16), Self(id: "sixty-four-queries", queryLimit: 64), Self(id: "twelve-workouts", detailWidth: 12), Self(id: "forty-eight-workouts", detailWidth: 48), Self(id: "details-after-history", serial: true), Self(id: "reserved-history-capacity", queryLimit: 24, historyCapacity: 8), Self(id: "small-cache", cacheRows: 50_000), Self(id: "large-cache", cacheRows: 800_000), Self(id: "selective-fallback", strategy: "selectiveFallback"), Self(id: "shared-statistics", strategy: "sharedStatistics"), Self(id: "wider-windows-known-regression", strategy: "widerStatistics"), Self(id: "combined-known-regression", strategy: "combined"), Self(id: "six-month-windows", chunkMonths: 6), Self(id: "fixed-input-large-batches", batchSize: 96, replay: true), Self(id: "daily-alone-cost-probe", family: "daily"), Self(id: "hourly-alone-cost-probe", family: "hourly"), Self(id: "workouts-alone-cost-probe", family: "workouts"), Self(id: "without-hourly-cost-probe", family: "noHourly"), Self(id: "without-routes-cost-probe", includeRoutes: false), Self(id: "separate-route-lane", shareRouteGate: false), Self(id: "statistics-error-recovery", fault: "error"), Self(id: "statistics-empty-recovery", fault: "empty"), Self(id: "statistics-partial-recovery", fault: "partial"), Self(id: "fixed-input-network-recovery", replay: true, fault: "network"), Self(id: "fixed-input-minimal-recorder", replay: true, instrument: false), Self(id: "without-raw-capture-overhead", captureRaw: false)]
        }
        a.append(Self(id: "baseline-end")); return a
    }

    static let families: Set<String> = ["all", "daily", "hourly", "workouts", "noHourly"]
    static let faults: Set<String> = ["", "error", "empty", "partial", "network"]
    static let maximumCases = 60

    /// Every numeric, enumerated and path-bearing field is bounded; a typo is rejected, never silently run as the baseline.
    var isValid: Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,80}$", options: .regularExpression) != nil
            && (1...8).contains(width) && (0...64).contains(queryLimit) && (1...64).contains(detailWidth)
            && (1...12).contains(uploadWidth) && (1...12).contains(groups) && (1...192).contains(batchSize) && (1...24).contains(chunkMonths)
            && (1...16).contains(routeWidth) && (0...32).contains(historyCapacity) && (0...2_000_000).contains(cacheRows)
            && Self.families.contains(family) && Self.faults.contains(fault)
            && (strategy == "baseline" || InitialSyncExperiments.Strategy(rawValue: strategy) != nil)
    }
    /// The first case is the live reference every other case is compared with, so it must be an ordinary complete read.
    var isCompleteLiveReference: Bool {
        id == "baseline-start" && !replay && fault.isEmpty && family == "all" && includeRoutes && strategy == "baseline" && captureRaw && instrument
    }
    /// A case whose live read matches the reference's reader behaviour, so its source replies and raw readings are comparable.
    func readsLikeReference(_ reference: Self) -> Bool {
        !replay && fault.isEmpty && family == "all" && includeRoutes && strategy == "baseline" && cacheRows == 0 && chunkMonths == reference.chunkMonths
    }
    /// Cases that are expected to change output by design (known-regression readers) or are incomplete-data cost probes.
    var isCostProbe: Bool { family != "all" || !includeRoutes }
    var expectsDifference: Bool { id.contains("known-regression") }

    static func validate(_ plan: [Self]) -> Bool {
        guard !plan.isEmpty, plan.count <= maximumCases, let first = plan.first, first.isCompleteLiveReference, Set(plan.map(\.id)).count == plan.count, plan.allSatisfy(\.isValid) else { return false }
        // A replay case reads the reference's captured replies, so a different window layout or scope would miss every key.
        return plan.allSatisfy { !$0.replay || ($0.chunkMonths == first.chunkMonths && $0.family == "all" && $0.includeRoutes) }
    }
}

enum DiagnosticSuite {
    struct Options: Sendable {
        var deep = false, delay = 2.0, cutoff = Calendar.current.startOfDay(for: Date())
        var resume: DiagnosticRunReport?, variants: [DiagnosticVariant]?
        var keepCaptures = false
    }
    static func run(scope: SyncScope, categories: Set<String>, options: Options,
                    sourceFactory: @escaping @Sendable (SyncScope) -> any HealthSource,
                    realUploader: (any Uploader)? = nil,
                    onUpdate: @escaping @Sendable (DiagnosticRunReport) -> Void) async throws -> DiagnosticRunReport {
        let reports = DiagnosticReportStore()
        var report = options.resume ?? DiagnosticRunReport()
        guard report.zone == TimeZone.current.identifier else { throw DiagnosticFailure.timeZoneChanged }
        let savedPlan = report.configuration["variantConfiguration"].flatMap { try? JSONDecoder().decode([DiagnosticVariant].self, from: Data($0.utf8)) }
        let plan = options.variants ?? savedPlan ?? DiagnosticVariant.plan(deep: options.deep)
        guard DiagnosticVariant.validate(plan) else { throw DiagnosticFailure.invalidConfiguration }
        if options.resume != nil && report.configuration["categories"] != categories.sorted().joined(separator: ",") { throw DiagnosticFailure.scopeChanged }
        if let free = freeBytes(reports.root), free < minimumFreeBytes { throw DiagnosticFailure.lowStorage }
        if options.resume == nil {
            report.preset = options.deep ? "Deep investigation" : "Full initial-sync diagnosis"; report.cutoff = options.cutoff
            report.coverage = DiagnosticCoverage.inventory(scope, categories: categories)
            report.configuration = ["uploadModel": "\(options.delay)s per batch", "categories": categories.sorted().joined(separator: ","), "variants": plan.map(\.id).joined(separator: ","), "keepCaptures": String(options.keepCaptures), "realTransfer": realUploader == nil ? "off" : "requested"]
            report.configuration["variantConfiguration"] = String(data: try JSONEncoder().encode(plan), encoding: .utf8)
            report.text = "\(report.preset)\n\(plan.count) full-history cases, fixed cutoff \(SleepNights.dayKey(report.cutoff, calendar: .current)). Every enabled metric is included.\nLocal uploads modeled at \(options.delay)s per batch. Phases overlap. Fresh app caches; Apple cache cannot be reset. Live cases include private capture/instrumentation overhead; replay excludes Apple Health latency.\n"
        }
        if options.resume == nil {
            let known = DiagnosticFixtures.run()
            report.configuration["knownAnswerFailures"] = String(known.filter { $0.hasPrefix("FAIL") }.count)
            report.text += known.joined(separator: "\n") + "\nNot exercised by this phone suite (covered only by unit/server tests, never inserted into Apple Health):\n" + DiagnosticFixtures.notExercised.map { "- " + $0 }.joined(separator: "\n") + "\n"
        }
        let root = reports.root.appendingPathComponent(report.id + "-private")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let baselineRoot = root.appendingPathComponent("baseline-start")
        var reference: DiagnosticRecordIndex?
        var baselineSink: DiagnosticBatchSink?
        if report.cases.contains(where: { $0.name == "baseline-start" }) {
            let sink = try DiagnosticBatchSink(root: baselineRoot.appendingPathComponent("batches"), delay: 0)
            baselineSink = sink; reference = try DiagnosticRecordIndex(sink: sink)
        }
        report.status = "running"
        onUpdate(report)
        defer { if report.status == "complete" && !options.keepCaptures { try? FileManager.default.removeItem(at: root) } }
        do {
            if reference != nil {
                let captured = RawReplayStore(scratch: try DiagnosticScratch(root: baselineRoot.appendingPathComponent("inputs")))
                try rawChecks(captured, report: &report, deep: options.deep, reports: reports, onUpdate: onUpdate)
            }
            if let realUploader, let sink = baselineSink, report.configuration["realTransfer"] != "done" {
                try await realTransfer(sink: sink, uploader: realUploader, report: &report, reports: reports, onUpdate: onUpdate)
            }
            for variant in plan where !report.cases.contains(where: { $0.name == variant.id }) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.thermalState != .critical else { throw DiagnosticFailure.thermalPause }
                let runRoot = root.appendingPathComponent(variant.id)
                if FileManager.default.fileExists(atPath: runRoot.path) { try FileManager.default.removeItem(at: runRoot) }
                let scratch = try DiagnosticScratch(root: runRoot.appendingPathComponent("inputs"))
                let sourceStore = SourceReplayStore(scratch: variant.replay ? try DiagnosticScratch(root: baselineRoot.appendingPathComponent("inputs")) : scratch)
                let raw = RawReplayStore(scratch: scratch)
                var selectedScope = scope
                if variant.family == "noHourly" || variant.family == "daily" || variant.family == "workouts" { selectedScope.hourly = [] }
                if variant.family == "hourly" || variant.family == "workouts" { selectedScope.dailyMetrics = [] }
                if variant.family == "daily" || variant.family == "hourly" { selectedScope.types = []; selectedScope.workoutQuantities = [] }
                if variant.family != "all" && variant.family != "noHourly" { selectedScope.events = [] }
                let base = sourceFactory(selectedScope)
                if let hk = base as? HealthKitSource { hk.setRouteConcurrency(variant.routeWidth); hk.routesShareQueryGate = variant.shareRouteGate }
                let source = DiagnosticSource(base: base, store: sourceStore, replay: variant.replay, omitWorkouts: selectedScope.workout == nil)

                let sink = try DiagnosticBatchSink(root: runRoot.appendingPathComponent("batches"), delay: options.delay, failOnce: variant.fault == "network")
                let box = Outbox(root: runRoot.appendingPathComponent("outbox"))
                let probe = SyncProbeRecorder()
                var config = SyncEngine.Config(); config.detailReadConcurrency = variant.detailWidth; config.uploadConcurrency = variant.uploadWidth; config.detailGroupsUploading = variant.groups; config.detailGroupSize = variant.batchSize
                config.diagnosticSerialPhases = variant.serial; config.diagnosticChunkMonths = variant.chunkMonths
                let savedCutoff = report.cutoff
                let engine = SyncEngine(source: source, uploader: sink, outbox: box, scope: selectedScope, config: config, now: { savedCutoff }, categories: { categories })
                let saved = report
                await engine.onProgress { p in var live = saved; live.text += "\nCase \(saved.cases.count + 1)/\(plan.count): \(variant.id) · \(p.detailsDone)/\(p.detailsTotal) workouts\n" + probe.summary(); onUpdate(live) }
                probe.count("configuration.dailyWidth", variant.width)
                let sampling = Task { @MainActor in
                    while !Task.isCancelled { probe.sampleDevice(); do { try await Task.sleep(for: .seconds(2)) } catch { break } }
                }
                let start = ProcessInfo.processInfo.systemUptime
                let outcome: SyncEngine.Outcome
                do {
                    outcome = try await SyncProbe.$runSalt.withValue(saved.id) { try await SyncProbe.$recorder.withValue(variant.instrument ? probe : nil) { try await SyncProbe.$statisticsFault.withValue(variant.fault) {
                        try await SyncProbe.$rawCapture.withValue(variant.replay || !variant.captureRaw ? nil : raw) {
                            try await PhoneSyncComparisonContext.$width.withValue(variant.width) {
                                try await PhoneSyncComparisonContext.$queryLimit.withValue(variant.queryLimit > 0 ? variant.queryLimit : nil) {
                                    try await PhoneSyncComparisonContext.$historyCapacity.withValue(variant.historyCapacity > 0 ? variant.historyCapacity : nil) { try await PhoneSyncComparisonContext.$cacheRows.withValue(variant.cacheRows > 0 ? variant.cacheRows : nil) { try await PhoneSyncComparisonContext.$includeRoutes.withValue(variant.includeRoutes) { try await PhoneSyncComparisonContext.$cutoff.withValue(saved.cutoff) {
                                        try await InitialSyncExperiments.$strategy.withValue(InitialSyncExperiments.Strategy(rawValue: variant.strategy)) {
                                            try await InitialSyncExperiments.$historyStart.withValue(try await source.earliestDailyDate()) {
                                                try await InitialSyncExperiments.$historyEnd.withValue(saved.cutoff) {
                                                    try await SyncTiming.$diagnostic.withValue(SyncTiming(persistEnabled: false)) {
                                                        do { return try await engine.run() } catch {
                                                            guard variant.fault == "network", !Task.isCancelled else { throw error }
                                                            probe.count("injectedNetworkFailureRecovered"); return try await engine.run()
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    } } } }
                                }
                            }
                        }
                    }
                } } } catch { sampling.cancel(); await sampling.value; throw error }
                let wall = ProcessInfo.processInfo.systemUptime - start
                sampling.cancel(); await sampling.value
                let index = try DiagnosticRecordIndex(sink: sink)
                let comparison = try reference.map { try index.compare(to: $0) }
                let complete = outcome == .finished && box.pending().isEmpty && box.state.detailsDone.count == box.state.workoutTotal && (selectedScope.dailyMetrics.isEmpty || box.state.dailyFullAt == saved.cutoff) && (selectedScope.hourly.isEmpty || box.state.hourlyAt == saved.cutoff)
                let snapshot = probe.snapshot()
                let referenceCase = report.cases.first(where: { $0.name == "baseline-start" })
                let liveInput = variant.replay ? nil : sourceStore.digest
                let liveRaw = variant.replay || !variant.captureRaw ? nil : raw.unorderedDigest()
                let kind = classify(variant: variant, reference: plan[0], complete: complete, comparison: comparison, referenceCase: referenceCase, liveInput: liveInput, liveRaw: liveRaw)
                var verdict = verdictText(kind)
                if !variant.fault.isEmpty { verdict += "; isolated fault-injection case, not a production timing" }
                if snapshot.devices.contains(where: { $0.thermal >= 2 }) { verdict += "; heat affected" }
                if snapshot.droppedTraceEvents > 0 { verdict += "; trace truncated (\(snapshot.droppedTraceEvents) events dropped, summaries complete)" }
                report.cases.append(DiagnosticCaseReport(name: variant.id, transfer: variant.replay ? "local simulated (fixed-input replay)" : "local simulated (live Apple Health)", elapsed: wall, records: index.count, complete: complete, verdict: verdict, changed: comparison?.changedRecords ?? 0, maximumDelta: comparison?.maximumDelta ?? 0, fields: comparison?.changedFields ?? [:], snapshot: snapshot, kind: kind, inputDigest: liveInput, rawDigest: liveRaw, exact: comparison?.exact))
                report.text += String(format: "\n%@: %.2fs elapsed · %d records · %@\n", variant.id, wall, index.count, verdict) + probe.summary() + "\nCounters: \(snapshot.counters)\n"
                if let comparison { report.text += "Changed fields: \(comparison.changedFields) · max delta \(comparison.maximumDelta)\n" }
                try reports.save(report); onUpdate(report)
                if variant.id == "baseline-start" {
                    reference = index; baselineSink = sink
                    updateCoverage(&report.coverage, sink: sink, snapshot: snapshot)
                    try rawChecks(raw, report: &report, deep: options.deep, reports: reports, onUpdate: onUpdate)
                    try reports.save(report); onUpdate(report)
                    // A selected real probe sends the already-prepared private batches, never the production outbox.
                    if let realUploader { try await realTransfer(sink: sink, uploader: realUploader, report: &report, reports: reports, onUpdate: onUpdate) }
                }
                if variant.id != "baseline-start" { try FileManager.default.removeItem(at: runRoot) }
            }
            if options.deep {
                report.text += "\nRepresentative HealthKit probes (separate from full-history timings):\n"
                let latest = report
                let collected = DiagnosticTextBuffer()
                await sourceFactory(scope).benchmark { text in collected.set(text); var live = latest; live.text += text; onUpdate(live) }
                try Task.checkCancellation()
                report.text += collected.value + "\n"
                report.text += "Representative probes complete; their timings are not full-sync completion times.\n"
            }
            report.status = "complete"
            if realUploader == nil, ["requested", "running"].contains(report.configuration["realTransfer"] ?? "") { report.configuration["realTransfer"] = "incomplete" }
            let gate = accuracyGate(cases: report.cases, knownAnswerFailures: Int(report.configuration["knownAnswerFailures"] ?? "0") ?? 0, rawDiffer: Int(report.configuration["rawReplayDiffer"] ?? "0") ?? 0, orderSensitive: Int(report.configuration["rawReplayOrderSensitive"] ?? "0") ?? 0, realTransfer: report.configuration["realTransfer"] ?? "off")
            report.configuration["accuracyGate"] = gate.verdict
            report.text += "\n" + gate.lines.joined(separator: "\n") + "\n"
            report.text += "\nCoverage: \(report.coverage.filter(\.enabled).count) enabled entries. See JSON for each metric.\nSuite finished. Finishing is not an accuracy pass: see the summary above. Faster candidates require repeated stable live runs; lower query counts alone do not qualify.\n"
            try reports.save(report); onUpdate(report); return report
        } catch {
            report.status = "paused"
            report.text += "\nPaused: \((error as NSError).domain) \((error as NSError).code). Completed cases saved. Resume starts an interrupted case from the beginning; history may have changed.\n"
            try reports.save(report); onUpdate(report); throw error
        }
    }
    private static func rawChecks(_ raw: RawReplayStore, report: inout DiagnosticRunReport, deep: Bool, reports: DiagnosticReportStore, onUpdate: @Sendable (DiagnosticRunReport) -> Void) throws {
        let completed = Int(report.configuration["rawReplayCompleted"] ?? "0") ?? 0
        for (i, f) in raw.inventory.enumerated() where i >= completed {
            try Task.checkCancellation()
            var live = report; live.text += "\nChecking raw replay: \(HealthTypes.shortName(f.type)) · \(f.count) readings"; onUpdate(live)
            let a = try raw.replay(f, unified: false), b = try raw.replay(f, unified: true)
            let agree = rawEqual(a, b)
            report.text += "Raw aggregate replay \(HealthTypes.shortName(f.type)): \(agree ? "MATCH" : "DIFFER") · \(f.count) readings\n"
            if !agree { report.configuration["rawReplayDiffer", default: "0"] = String((Int(report.configuration["rawReplayDiffer"] ?? "0") ?? 0) + 1) }
            if deep && f.count <= 10_000 {
                let reversed = try raw.replay(f, unified: false, reverse: true)
                if !rawEqual(a, reversed) { report.text += "ORDER-SENSITIVE aggregate: \(HealthTypes.shortName(f.type))\n"; report.configuration["rawReplayOrderSensitive", default: "0"] = String((Int(report.configuration["rawReplayOrderSensitive"] ?? "0") ?? 0) + 1) }
            }
            report.configuration["rawReplayCompleted"] = String(i + 1); try reports.save(report)
        }
    }
    static func rawEqual(_ a: RawHistorySummary, _ b: RawHistorySummary) -> Bool {
        guard Set(a.daily.keys) == Set(b.daily.keys), a.hourly.count == b.hourly.count else { return false }
        for key in a.daily.keys { let x = a.daily[key]!, y = b.daily[key]!; if x.count != y.count { return false }; for (u, v) in zip(x, y) { if u.0 != v.0 || abs(u.1 - v.1) > 1e-9 { return false } } }
        for (u, v) in zip(a.hourly, b.hourly) { if u.t != v.t || !equalOptional(u.v, v.v) || u.lo != v.lo || u.hi != v.hi { return false } }
        return true
    }
    private static func equalOptional(_ a: Double?, _ b: Double?) -> Bool { switch (a, b) { case (nil, nil): return true; case let (a?, b?): return abs(a - b) <= 1e-9; default: return false } }
    private static func updateCoverage(_ rows: inout [DiagnosticCoverage], sink: DiagnosticBatchSink, snapshot: SyncProbeRecorder.Snapshot) {
        for (_, file) in sink.batches {
            guard let data = try? Data(contentsOf: file), let bytes = Gzip.decompress(data) else { continue }
            for line in bytes.split(separator: 10).dropFirst() {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let q = obj["m"] as? [String: Any] { for key in q.keys { for i in rows.indices where rows[i].metric == key { rows[i].records += 1 } } }
                if let q = obj["m"] as? [String: Any], let specs = HealthTypes.loadCoverage()?.dailyMetrics {
                    for spec in specs where spec.outputs?.contains(where: { q[$0] != nil }) == true { for i in rows.indices where rows[i].metric == spec.key && q[spec.key] == nil { rows[i].records += 1 } }
                }
                let kind = obj["k"] as? String ?? ""
                let additional: [String] = kind == "w" ? ["summaries"] : kind == "ws" ? ((obj["st"] as? String == "route") ? ["routes", "series"] : ["series"]) : kind == "meta" ? ["profile"] : []
                for name in additional { for i in rows.indices where rows[i].metric == name { rows[i].records += 1 } }
                if let ty = (obj["ty"] ?? obj["st"]) as? String { for i in rows.indices where rows[i].metric == ty { rows[i].records += 1 } }
            }
        }
        for i in rows.indices where rows[i].enabled { rows[i].status = coverageStatus(rows[i], snapshot: snapshot) }
    }
    /// A read that failed or was retried is not "no data", and an empty read never proves absence or denial.
    static func coverageStatus(_ row: DiagnosticCoverage, snapshot: SyncProbeRecorder.Snapshot) -> String {
        let prefix: String
        switch row.family {
        case "daily": prefix = "daily." + row.metric + "|"
        case "hourly": prefix = "hourly." + row.metric + "|"
        case "workout quantity": prefix = "workout." + row.metric + "|"
        default: prefix = ""
        }
        let related = prefix.isEmpty ? [] : snapshot.stats.filter { $0.key.hasPrefix(prefix) }.map(\.value)
        let errors = related.reduce(0) { $0 + $1.errors }, calls = related.reduce(0) { $0 + $1.count }
        if row.records > 0 { return errors > 0 ? "readable data; \(errors) failed or retried read(s) recorded" : "readable data" }
        if errors > 0 { return "read failed or was retried \(errors) time(s); not evidence of absent data" }
        if calls > 0 { return "read completed but returned no records (absent data or no read permission; HealthKit does not say which)" }
        return prefix.isEmpty ? "no records in the returned stream; no per-metric read timing exists for this entry" : "no records returned and no read recorded for this metric in the reference run"
    }
    enum DiagnosticFailure: Error, CustomStringConvertible {
        case thermalPause, timeZoneChanged, invalidConfiguration, scopeChanged, lowStorage
        var description: String {
            switch self {
            case .thermalPause: return "The phone is too hot. Let it cool, then resume."
            case .timeZoneChanged: return "The time zone changed since this report started. Start a new diagnosis."
            case .invalidConfiguration: return "The experiment configuration is not valid (the first case must be an ordinary live baseline-start; check numbers, names, family, fault and strategy)."
            case .scopeChanged: return "The enabled data categories changed since this report started. Start a new diagnosis."
            case .lowStorage: return "Not enough free storage for private replay captures (about 2 GB needed). Free space and try again."
            }
        }
    }
    static let minimumFreeBytes: Int64 = 2_000_000_000
    static func freeBytes(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    static func classify(variant: DiagnosticVariant, reference: DiagnosticVariant, complete: Bool, comparison: HistoryRecordComparison?, referenceCase: DiagnosticCaseReport?, liveInput: String?, liveRaw: String?) -> String {
        if !complete { return "incomplete" }
        if variant.isCostProbe { return "costProbe" }
        if variant.id == reference.id { return "reference" }
        guard comparison?.equivalent == false else { return "matched" }
        if variant.replay { return "replayRegression" }
        if variant.expectsDifference { return "knownRegression" }
        if !variant.fault.isEmpty { return "recoveryDifference" }
        guard variant.readsLikeReference(reference), let referenceCase else { return "candidateDifference" }
        if let liveInput, liveInput == referenceCase.inputDigest { return "engineDifference" }
        if let liveRaw, let rawReference = referenceCase.rawDigest, liveRaw == rawReference { return "readerDifference" }
        return "sourceChanged"
    }
    static func verdictText(_ kind: String) -> String {
        switch kind {
        case "incomplete": return "INCOMPLETE — the case did not finish all required work"
        case "costProbe": return "INCOMPLETE-DATA COST PROBE — not a full-sync optimization"
        case "reference": return "REFERENCE CAPTURED — first live read; later cases are compared with it, not certified"
        case "matched": return "OUTPUT MATCHED the reference record by record in this run (regression evidence only; Apple's private aggregation is not independently certified)"
        case "replayRegression": return "REPLAY REGRESSION — identical captured inputs produced different records"
        case "knownRegression": return "KNOWN-REGRESSION READER differs from the reference as expected — do not enable"
        case "recoveryDifference": return "RECOVERY DIFFERENCE — the injected statistics fault changed records versus the reference"
        case "engineDifference": return "ENGINE/ENCODING DIFFERENCE — identical source replies produced different records"
        case "readerDifference": return "READER DIFFERENCE — identical raw readings produced different source replies"
        case "sourceChanged": return "SOURCE OR READ-SET CHANGED — Apple Health responses differed from the reference run; not attributable to this configuration"
        case "candidateDifference": return "CANDIDATE OUTPUT DIFFERENCE — this reader changes records versus the reference"
        default: return kind
        }
    }

    struct AccuracyGate: Sendable { let verdict: String; let lines: [String] }
    static func accuracyGate(cases: [DiagnosticCaseReport], knownAnswerFailures: Int, rawDiffer: Int, orderSensitive: Int, realTransfer: String) -> AccuracyGate {
        func count(_ kind: String) -> Int { cases.filter { $0.kind == kind }.count }
        let replays = cases.filter { $0.transfer.contains("replay") }
        let end = cases.first { $0.name == "baseline-end" }
        let stability = end.map { $0.kind == "matched" ? "stable" : $0.kind == "incomplete" ? "not measured (baseline-end incomplete)" : "UNSTABLE (\($0.changed) records changed)" } ?? "not measured (no baseline-end)"
        let failures = [("known-answer fixture", knownAnswerFailures), ("replay regression", count("replayRegression")), ("engine/encoding difference", count("engineDifference")), ("reader difference", count("readerDifference")), ("raw aggregate path disagreement", rawDiffer)].filter { $0.1 > 0 }
        var lines = ["ACCURACY SUMMARY — record-by-record comparison with baseline-start (regression evidence, not independent certification)"]
        lines.append("Known-answer fixtures: \(knownAnswerFailures == 0 ? "all passed" : "\(knownAnswerFailures) FAILED")")
        lines.append("Repeat live baseline: \(stability)")
        lines.append("Fixed-input replay: \(replays.filter { $0.kind == "matched" }.count) matched, \(count("replayRegression")) regressions")
        lines.append("Raw aggregate replay: \(rawDiffer) path disagreements, \(orderSensitive) order-sensitive aggregates")
        lines.append("Live matched: \(cases.filter { $0.kind == "matched" && !$0.transfer.contains("replay") }.count) · source/read-set changed: \(count("sourceChanged")) · reader differences: \(count("readerDifference")) · engine differences: \(count("engineDifference"))")
        lines.append("Candidate readers differing: \(count("candidateDifference")) · recovery differences: \(count("recoveryDifference")) · known-regression readers that differed as expected: \(count("knownRegression"))")
        lines.append("Incomplete cases: \(count("incomplete")) · incomplete-data cost probes (not accuracy results): \(count("costProbe"))")
        let noisy = cases.filter { $0.exact == false && $0.maximumDelta <= 1e-9 }
        lines.append(noisy.isEmpty ? "Numeric exactness: every compared case was byte-identical to the reference" : "Numeric exactness: \(noisy.count) case(s) were not byte-identical but stayed inside the 1e-9 tolerance (largest delta \(noisy.map(\.maximumDelta).max() ?? 0)); the tolerance was not relaxed")
        lines.append("Isolated real transfer: \(realTransfer)")
        let verdict: String
        if !failures.isEmpty { verdict = "FAILED — " + failures.map { "\($0.1) \($0.0)" }.joined(separator: ", ") }
        else if count("incomplete") > 0 { verdict = "INCOMPLETE — \(count("incomplete")) case(s) did not finish, so no accuracy conclusion for them" }
        else if count("sourceChanged") > 0 || stability.hasPrefix("UNSTABLE") { verdict = "INCONCLUSIVE — Apple Health responses changed between live runs, so live differences cannot be attributed to a configuration" }
        else if count("candidateDifference") + count("recoveryDifference") > 0 { verdict = "CANDIDATE DIFFERENCES — at least one reader or recovery path changed records; do not adopt it" }
        else { verdict = "NO REGRESSION DETECTED in the tested cases (agreement with this phone's own reference reader only)" }
        lines.append("OVERALL: " + verdict)
        return AccuracyGate(verdict: verdict, lines: lines)
    }

    /// Sends the prepared private batches one by one to the isolated sandbox. Progress is checkpointed per batch so a
    /// paused report resumes the remaining batches; a transfer that was never completed is reported as such.
    static func realTransfer(sink: DiagnosticBatchSink, uploader: any Uploader, report: inout DiagnosticRunReport, reports: DiagnosticReportStore, onUpdate: @Sendable (DiagnosticRunReport) -> Void) async throws {
        let batches = sink.batches
        var done = Int(report.configuration["realTransferBatches"] ?? "0") ?? 0
        var seconds = Double(report.configuration["realTransferSeconds"] ?? "0") ?? 0
        report.configuration["realTransfer"] = "running"
        let started = ProcessInfo.processInfo.systemUptime
        do {
            while done < batches.count {
                try Task.checkCancellation()
                let type = batches[done].0, file = batches[done].1
                let data = try Data(contentsOf: file)
                if data.count > 5 * 1024 * 1024 {
                    // The sandbox endpoint accepts at most 5 MB per batch; say so instead of failing the whole transfer.
                    report.configuration["realTransferSkipped"] = String((Int(report.configuration["realTransferSkipped"] ?? "0") ?? 0) + 1)
                    done += 1; report.configuration["realTransferBatches"] = String(done); continue
                }
                try await uploader.upload(batchId: UUID().uuidString.lowercased(), gz: data, sha256: DiagnosticScratch.digest(data), typeId: type)
                done += 1; report.configuration["realTransferBatches"] = String(done)
                if done % 10 == 0 { var live = report; live.text += "\nIsolated real transfer: \(done)/\(batches.count) batches"; onUpdate(live); try reports.save(report) }
            }
        } catch {
            report.configuration["realTransferSeconds"] = String(seconds + ProcessInfo.processInfo.systemUptime - started); throw error
        }
        seconds += ProcessInfo.processInfo.systemUptime - started
        report.configuration["realTransferSeconds"] = String(seconds)
        report.configuration["realTransfer"] = "done"
        if let transfer = uploader as? any DiagnosticTransferReporting { report.text += "\n" + transfer.transferSummary() + "\n" }
        if let skipped = report.configuration["realTransferSkipped"] { report.text += "Skipped \(skipped) batch(es) larger than the sandbox's 5 MB limit; they were not read back.\n" }
        report.text += String(format: "Isolated real transfer/readback: %d batches in %.2fs of transfer time across this report's sessions. Each batch is ingested and read back separately in a request-local sandbox, serially after preparation; this is not an end-to-end pipelined initial upload and not cross-batch MCP certification.\n", batches.count, seconds)
        try reports.save(report); onUpdate(report)
    }
}

private final class DiagnosticTextBuffer: @unchecked Sendable {
    private let lock = NSLock(); private var text = ""
    func set(_ value: String) { lock.withLock { text = value } }
    var value: String { lock.withLock { text } }
}
