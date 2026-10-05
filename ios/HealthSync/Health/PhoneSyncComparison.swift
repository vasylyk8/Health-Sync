import Foundation
import HealthKit
import UIKit

/// Overrides exist only inside the diagnostic task tree; normal syncs retain width two.
enum PhoneSyncComparisonContext {
    @TaskLocal static var width: Int?
    @TaskLocal static var cutoff: Date?
    static var samplePredicate: NSPredicate? {
        cutoff.map { HKQuery.predicateForSamples(withStart: nil, end: $0, options: .strictEndDate) }
    }
}

enum PhoneSyncComparison {
    struct Options: Sendable {
        // Mirror the order so each width runs twice at complementary positions.
        var order = Bool.random() ? [1, 2, 4, 4, 2, 1] : [1, 4, 2, 2, 4, 1]
        var strategies: [InitialSyncExperiments.Strategy]?
        var uploadDelay: TimeInterval = 2
        var coolingTimeout: TimeInterval = 600
        var cutoff = Calendar.current.startOfDay(for: Date())
    }
    struct Run: Sendable {
        let width: Int, wall: Double, records: Int
        var strategy: InitialSyncExperiments.Strategy = .baseline
        let complete: Bool, comparison: HistoryRecordComparison?
    }
    struct Result: Sendable {
        let runs: [Run], report: String
        var passed: Bool { !runs.isEmpty && runs.allSatisfy { $0.complete && ($0.comparison?.equivalent ?? true) } }
    }

    /// Uses no authorization writes, fixture seeding, backend or production outbox.
    static func run(scope: SyncScope, categories: Set<String>, options: Options = Options(),
                    sourceFactory: @escaping @Sendable () -> any HealthSource,
                    onUpdate: @escaping @Sendable (String) -> Void) async throws -> Result {
        guard options.order.first == 1, options.order.allSatisfy({ [1, 2, 4].contains($0) }) else { throw InvalidOrder() }
        guard options.strategies == nil || options.strategies?.count == options.order.count else { throw InvalidOrder() }
        let fm = FileManager.default
        let parent = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("PhoneSyncComparison", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        // AppModel allows one comparison. Remove abandoned private scratch data from a prior exit.
        for old in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) { try fm.removeItem(at: old) }
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var protectedRoot = root
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        try protectedRoot.setResourceValues(resource)
        defer { try? fm.removeItem(at: root) }
        let initialHeat = ProcessInfo.processInfo.thermalState.rawValue
        let initialPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard initialHeat <= ProcessInfo.ThermalState.fair.rawValue else { throw TooHot() }
        var report = "Initial sync comparison\nReads real history before \(SleepNights.dayKey(options.cutoff, calendar: .current)) (today excluded).\nNormal encoding, compression and isolated local outboxes; uploads simulated at \(options.uploadDelay)s per batch. No server requests.\nOrder: \(options.order.map(String.init).joined(separator: ", ")). Each run has a new source/cache/outbox; Apple Health's own cache cannot be reset.\nKeep KROK open and the phone unlocked. Switching apps stops the test. Phase durations overlap; upload totals sum overlapping requests.\n"
        onUpdate(report)
        var reference: DiagnosticRecordIndex?
        var runs: [Run] = []
        for (number, width) in options.order.enumerated() {
            try Task.checkCancellation()
            let coolStarted = ProcessInfo.processInfo.systemUptime
            while options.coolingTimeout > 0 && ProcessInfo.processInfo.thermalState.rawValue > initialHeat {
                onUpdate(report + "\nCooling before run \(number + 1)/\(options.order.count)… You can stop and retry later.")
                guard ProcessInfo.processInfo.systemUptime - coolStarted < options.coolingTimeout else { throw TooHot() }
                try await Task.sleep(for: .seconds(3))
            }
            guard ProcessInfo.processInfo.isLowPowerModeEnabled == initialPower else { throw ConditionsChanged() }
            let runRoot = root.appendingPathComponent("run-\(number)")
            let sink = try DiagnosticBatchSink(root: runRoot.appendingPathComponent("capture"), delay: options.uploadDelay)
            let box = Outbox(root: runRoot.appendingPathComponent("outbox"))
            let phases = DiagnosticPhaseTimes()
            let source = sourceFactory()
            let strategy = options.strategies?[number] ?? .baseline
            let statisticsCache = DailyStatisticsCache()
            var config = SyncEngine.Config()
            config.phaseObserver = { phases.record($0, start: $1, end: $2) }
            let engine = SyncEngine(source: source, uploader: sink, outbox: box, scope: scope, config: config,
                                    now: { options.cutoff }, categories: { categories })
            let prefix = report
            await engine.onProgress { progress in
                onUpdate(prefix + "\nRun \(number + 1)/\(options.order.count): \(width) daily reads · \(progress.detailsDone)/\(progress.detailsTotal) workouts · \(progress.phaseHint ?? "Reading and preparing batches…")")
            }
            let heat = ProcessInfo.processInfo.thermalState.rawValue
            let start = ProcessInfo.processInfo.systemUptime
            let timing = SyncTiming(persistEnabled: false)
            let outcome = try await PhoneSyncComparisonContext.$width.withValue(width) {
                try await PhoneSyncComparisonContext.$cutoff.withValue(options.cutoff) {
                    try await SyncTiming.$diagnostic.withValue(timing) {
                        try await InitialSyncExperiments.$strategy.withValue(options.strategies == nil ? nil : strategy) {
                            let historyStart = strategy.wider ? try await source.earliestDailyDate().map { Calendar.current.startOfDay(for: $0) } : nil
                            return try await InitialSyncExperiments.$historyStart.withValue(historyStart) {
                                try await InitialSyncExperiments.$historyEnd.withValue(options.cutoff) {
                                    try await InitialSyncExperiments.$statistics.withValue(statisticsCache) {
                                        try await withTaskCancellationHandler { try await engine.run() }
                                            onCancel: { Task { await statisticsCache.cancelAll() } }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            let wall = ProcessInfo.processInfo.systemUptime - start
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.isLowPowerModeEnabled == initialPower else { throw ConditionsChanged() }
            let index = try await work { try DiagnosticRecordIndex(sink: sink) }
            let comparison: HistoryRecordComparison?
            if let reference { comparison = try await work { try index.compare(to: reference) } }
            else { reference = index; comparison = nil }
            // A backdated daily marker means a suspect chunk, not a successful complete read.
            let complete = outcome == .finished && box.pending().isEmpty && box.state.detailsDone.count == box.state.workoutTotal
                && box.state.workoutTotal > 0 && index.count > 0
                && box.state.dailyFullAt == options.cutoff && box.state.hourlyAt == options.cutoff
            runs.append(Run(width: width, wall: wall, records: index.count, strategy: strategy, complete: complete, comparison: comparison))
            report += String(format: "\nRun %d · width %d · total %.2fs · %@ · %d/%d workouts · %d health records · heat %d→%d\n%@\n%@\n%@\n%@\n", number + 1, width, wall, complete ? "complete" : "INCOMPLETE", box.state.detailsDone.count, box.state.workoutTotal, index.count, heat, ProcessInfo.processInfo.thermalState.rawValue, phases.summary(), sink.summary(), timing.diagnosticSummary(), comparison.map { "Against serial run 1: \($0.equivalent ? "MATCH" : "DIFFER") · exact=\($0.exact) · changed=\($0.changedRecords) · max numeric delta=\($0.maximumDelta)" } ?? "Serial reference captured. Every health record and duplicate occurrence is compared; batch headers are excluded.")
            if options.strategies != nil { report += "Strategy: \(strategy.rawValue)\n" }
            if let comparison, !comparison.equivalent { report += comparison.detailSummary + "\n" }
            if options.strategies != nil { report += "Statistics cache hits: \(await statisticsCache.hits) \(timing.experimentSummary)\n" }
            onUpdate(report)
            if number > 0 { try fm.removeItem(at: runRoot) }
        }
        if options.strategies != nil {
            report += "\nStrategy means at width 2 (simulated uploads):\n"
            for strategy in InitialSyncExperiments.Strategy.allCases {
                let selected = runs.filter { $0.strategy == strategy && $0.width == 2 }
                guard !selected.isEmpty else { continue }
                report += String(format: "%@: %.2fs (%d runs), %@\n", strategy.rawValue,
                                 selected.map(\.wall).reduce(0, +) / Double(selected.count), selected.count,
                                 selected.allSatisfy { $0.complete && ($0.comparison?.equivalent ?? true) } ? "records match serial" : "needs investigation")
            }
        }
        report += "\nMeans by width (observed conditions, simulated uploads):\n"
        for width in [1, 2, 4] {
            let selected = runs.filter { $0.width == width }
            guard !selected.isEmpty else { continue }
            report += String(format: "%d daily reads: %.2fs mean (range %.2f–%.2f), %@\n", width, selected.map(\.wall).reduce(0, +) / Double(selected.count), selected.map(\.wall).min()!, selected.map(\.wall).max()!, selected.allSatisfy { $0.complete && ($0.comparison?.equivalent ?? true) } ? "records match serial" : "needs investigation")
        }
        let passed = runs.allSatisfy { $0.complete && ($0.comparison?.equivalent ?? true) }
        report += passed ? "PHONESYNC CHECK OK\n" : "PHONESYNC CHECK FAILED · differences may reflect changed Health data or reader behavior; investigate before selecting a width.\n"
        report += "Numeric comparisons allow at most 1e-9 absolute floating-point noise; values are never rounded for upload. Matching serial output does not independently certify Apple's private aggregation rules. Private scratch batches are removed after the test.\nDone."
        onUpdate(report)
        return Result(runs: runs, report: report)
    }

    private static func work<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try body() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    struct InvalidOrder: Error {}
    struct TooHot: Error {}
    struct ConditionsChanged: Error {}
}

final class DiagnosticPhaseTimes: @unchecked Sendable {
    private let lock = NSLock()
    private var times: [String: Double] = [:]
    func record(_ name: String, start: Double, end: Double) { lock.withLock { times[name] = end - start } }
    func summary() -> String {
        lock.withLock { ["daily", "hourly", "details"].map { name in times[name].map { String(format: "%@ %.2fs", name, $0) } ?? "\(name) NOT MEASURED" }.joined(separator: " · ") }
    }
}
