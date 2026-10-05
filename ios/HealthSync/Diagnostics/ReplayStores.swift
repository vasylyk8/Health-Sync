import CryptoKit
import Foundation

/// Bounded protected scratch capture; never a production outbox or a shared report.
final class DiagnosticScratch: @unchecked Sendable {
    let root: URL
    private let lock = NSLock()
    private var bytes = 0
    let limit: Int
    init(root: URL, limit: Int = 1_000_000_000) throws {
        self.root = root; self.limit = limit
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var url = root; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values)
    }
    func reserve(_ count: Int) throws { try lock.withLock { guard count >= 0, bytes + count <= limit else { throw Failure.storageLimit }; bytes += count } }
    func write(_ data: Data, name: String) throws { try reserve(data.count); try data.write(to: root.appendingPathComponent(name), options: [.atomic, .completeFileProtection]) }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    enum Failure: Error { case storageLimit, missingReplay, corruptCapture }
}

final class SourceReplayStore: @unchecked Sendable {
    struct Group: Codable, Sendable { var type: String, category: String, records: [Record], note: String?, incomplete: Bool }
    struct Ref: Codable, Sendable { var id: String, start: Date }
    struct Reply: Codable, Sendable {
        var records: [Record] = [], groups: [Group] = [], refs: [Ref] = []
        var anchor: Data?, count = 0, date: Date?, absent = false
    }
    let scratch: DiagnosticScratch
    private let lock = NSLock()
    private var fingerprints: [String: String] = [:]
    init(scratch: DiagnosticScratch) { self.scratch = scratch }
    func capture(_ key: String, reply: Reply) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(reply), name = DiagnosticScratch.digest(Data(key.utf8))
        let compressed = Gzip.compress(data)
        try scratch.write(compressed, name: name + ".source.gz")
        lock.withLock { fingerprints[name] = DiagnosticScratch.digest(data) }
    }
    func read(_ key: String) throws -> Reply {
        let name = DiagnosticScratch.digest(Data(key.utf8))
        guard let data = Gzip.decompress(try Data(contentsOf: scratch.root.appendingPathComponent(name + ".source.gz"))) else { throw DiagnosticScratch.Failure.missingReplay }
        return try JSONDecoder().decode(Reply.self, from: data)
    }
    var digest: String { lock.withLock { DiagnosticScratch.digest(Data(fingerprints.sorted { $0.key < $1.key }.map { $0.key + ":" + $0.value }.joined(separator: "\n").utf8)) } }
}

final class DiagnosticSource: HealthSource, @unchecked Sendable {
    let base: any HealthSource, store: SourceReplayStore
    let replay: Bool
    init(base: any HealthSource, store: SourceReplayStore, replay: Bool) { self.base = base; self.store = store; self.replay = replay }
    var isAvailable: Bool { base.isAvailable }
    func requestAuthorization(scope: SyncScope) async throws {}
    func observeWorkouts(onChange: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {}
    var queryConcurrency: Int { base.queryConcurrency }
    func setQueryConcurrency(_ n: Int) { if !replay { base.setQueryConcurrency(n) } }
    private func call(_ key: String, _ body: () async throws -> SourceReplayStore.Reply) async throws -> SourceReplayStore.Reply {
        if replay { return try await SyncProbe.measure("source.replay") { try store.read(key) } }
        let reply = try await body()
        try SyncProbe.measureSync("capture.source") { try store.capture(key, reply: reply) }; return reply
    }
    func workouts(from: Date, to: Date) async throws -> [Record] { try await call("recent|\(from.msValue)|\(to.msValue)") { .init(records: try await base.workouts(from: from, to: to)) }.records }
    func workoutIndex() async throws -> [WorkoutRef] { try await call("index") { .init(refs: try await base.workoutIndex().map { .init(id: $0.id, start: $0.start) }) }.refs.map { WorkoutRef(id: $0.id, start: $0.start) } }
    func workoutDetail(id: String, gen: Int64) async throws -> [Record]? {
        let result = try await call("detail|\(id)|\(gen)") { let r = try await base.workoutDetail(id: id, gen: gen); return .init(records: r ?? [], absent: r == nil) }
        return result.absent ? nil : result.records
    }
    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        let key = "page|\(type.id)|\(anchor.map(DiagnosticScratch.digest) ?? "nil")|\(limit)"
        let r = try await call(key) { let p = try await base.anchoredPage(type, anchor: anchor, limit: limit); return .init(records: p.records, anchor: p.newAnchor, count: p.objectCount) }
        return AnchoredPage(records: r.records, newAnchor: r.anchor, objectCount: r.count)
    }
    func dailyContext(from: Date, to: Date) async throws -> [Record] { try await base.dailyContext(from: from, to: to) }
    func dailyContextBatches(from: Date, to: Date, categories: Set<String>) async throws -> [DailyBatch] {
        try await call("daily|\(from.msValue)|\(to.msValue)|\(categories.sorted().joined(separator: ","))") {
            .init(groups: try await base.dailyContextBatches(from: from, to: to, categories: categories).map { .init(type: $0.typeId, category: $0.category, records: $0.records, note: $0.note, incomplete: $0.incomplete) })
        }.groups.map { DailyBatch(typeId: $0.type, category: $0.category, records: $0.records, note: $0.note, incomplete: $0.incomplete) }
    }
    func hourlySeries(from: Date, to: Date) async throws -> [Record] { try await call("hourly|\(from.msValue)|\(to.msValue)") { .init(records: try await base.hourlySeries(from: from, to: to)) }.records }
    func profileRecords() async throws -> [Record] { try await call("profile") { .init(records: try await base.profileRecords()) }.records }
    func earliestDailyDate() async throws -> Date? { try await call("earliest") { .init(date: try await base.earliestDailyDate()) }.date }
    func dailyDiagnosticNote() -> String? { replay ? "fixed-input replay" : base.dailyDiagnosticNote() }
    func hourlyDiagnosticNote() -> String? { replay ? "fixed-input replay" : base.hourlyDiagnosticNote() }
}

/// Raw conversion output before aggregation, retaining row order for order-sensitivity tests.
final class RawReplayStore: @unchecked Sendable {
    struct Fixture: Codable, Sendable { var name: String, type: String, from: Date, to: Date, style: SampleAggregator.Style, count: Int, fingerprint: String }
    struct Row: Codable { let id: String; let reading: RawReading }
    final class Writer {
        let store: RawReplayStore, handle: FileHandle
        var fixture: Fixture, buffer = Data(), hash = SHA256()
        init(store: RawReplayStore, fixture: Fixture) throws {
            self.store = store; self.fixture = fixture
            let url = store.scratch.root.appendingPathComponent(fixture.name)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.protectionKey: FileProtectionType.complete]); handle = try FileHandle(forWritingTo: url)
        }
        func append(_ reading: RawReading, id: String) throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var row = try encoder.encode(Row(id: id, reading: reading)); row.append(10); hash.update(data: row); buffer.append(row); fixture.count += 1
            if buffer.count > 65_536 { try flush() }
        }
        private func flush() throws { guard !buffer.isEmpty else { return }; try store.scratch.reserve(buffer.count); try handle.write(contentsOf: buffer); buffer.removeAll(keepingCapacity: true) }
        func finish() throws { try flush(); try handle.close(); fixture.fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined(); store.add(fixture) }
    }
    let scratch: DiagnosticScratch
    private let lock = NSLock(); private var fixtures: [Fixture] = []
    init(scratch: DiagnosticScratch) { self.scratch = scratch }
    func writer(type: String, from: Date, to: Date, style: SampleAggregator.Style) throws -> Writer {
        try Writer(store: self, fixture: Fixture(name: UUID().uuidString + ".raw.ndjson", type: type, from: from, to: to, style: style, count: 0, fingerprint: ""))
    }
    private func add(_ f: Fixture) { lock.withLock { fixtures.append(f) } }
    var inventory: [Fixture] { lock.withLock { fixtures } }
    func replay(_ f: Fixture, unified: Bool, reverse: Bool = false) throws -> RawHistorySummary {
        var day = SampleAggregator(calendar: .current, from: f.from, to: f.to, style: f.style, granularity: .day)
        var hour = SampleAggregator(calendar: .current, from: f.from, to: f.to, style: f.style, granularity: .hour)
        let data = try Data(contentsOf: scratch.root.appendingPathComponent(f.name), options: .mappedIfSafe)
        let rows = data.split(separator: 10)
        for line in (reverse ? Array(rows.reversed()) : rows) {
            try Task.checkCancellation(); let r = try JSONDecoder().decode(Row.self, from: Data(line)).reading
            day.add(r); if !(unified && f.style == .cumulative) { hour.add(r) }
        }
        if unified && f.style == .cumulative { return day.cumulativeDailyHourly(includeHourly: true) }
        let daily = Dictionary(uniqueKeysWithValues: [DailyAgg.sum, .avg, .min, .max, .last].map { ($0.rawValue, day.daily($0)) })
        return RawHistorySummary(daily: daily, hourly: hour.hourly(avg: true, min: true, max: true))
    }
}
