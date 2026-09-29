import Foundation

/// Durable on-disk queue. A HealthKit query result and the anchor that follows it are written
/// together BEFORE uploading; the anchor is committed only after every batch of that result has
/// been accepted by the server. A crash or network failure at any point never loses data.
final class Outbox: @unchecked Sendable {
    struct Entry: Codable, Equatable {
        let id: String
        let typeId: String
        var batchIds: [String]
        var uploaded: [String]
        /// Anchor to commit once all batches are uploaded (nil = nothing to commit).
        var anchor: Data?
        /// State changes to apply on completion (e.g. mark the recent pass done).
        var completes: Completion?
        /// Outbox generation this copy belongs to (not persisted). After `reset()` older copies are stale.
        var generation = 0

        private enum CodingKeys: String, CodingKey { case id, typeId, batchIds, uploaded, anchor, completes }
    }

    enum Completion: Codable, Equatable {
        case recentDone
        case statsFull(Date)
        case caughtUp
        /// A status batch confirmed these types are fully synced.
        case caughtUpMany([String])
        case reconcileDone
        case activityInitial
        case correlationInitial
        case profile(String)
    }

    struct State: Codable, Equatable {
        var anchors: [String: Data] = [:]
        var seq: [String: Int64] = [:]
        var recentDone: Set<String> = []
        var caughtUp: Set<String> = []
        var statsFullAt: [String: Date] = [:]
        var earliest: [String: Date] = [:]
        var reconcile: [String: String] = [:]
        var activityInitialDone = false
        var correlationInitialDone: Set<String> = []
        var profileHash: String?
        var lastSyncAt: Date?
    }

    let root: URL
    private(set) var state: State
    /// Bumped by `reset()`. Entries read or created earlier must not write state afterwards
    /// (an upload that was in flight when the user deleted everything).
    private var generation = 0
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("batches"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("pending"), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: root.appendingPathComponent("state.json")), let s = try? JSONDecoder().decode(State.self, from: data) {
            state = s
        } else {
            state = State()
        }
    }

    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var url = base.appendingPathComponent("outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
        return url
    }

    func update(_ change: (inout State) -> Void) throws {
        var s = state
        change(&s)
        try write(JSONEncoder().encode(s), to: root.appendingPathComponent("state.json"))
        state = s
    }

    /// Reserves the next sequence number for a type (persisted before use, so it never repeats).
    func nextSeq(_ typeId: String) throws -> Int64 {
        var n: Int64 = 0
        try update { s in
            n = (s.seq[typeId] ?? 0) + 1
            s.seq[typeId] = n
        }
        return n
    }

    func enqueue(typeId: String, batches: [Batch], anchor: Data?, completes: Completion?) throws -> Entry {
        for b in batches { try write(b.gz, to: batchURL(b.id)) }
        // Sortable id: entries are always retried in the order they were created.
        let id = String(format: "%016llu-%@", UInt64(Date().timeIntervalSince1970 * 1_000_000), UUID().uuidString)
        let entry = Entry(id: id, typeId: typeId, batchIds: batches.map(\.id), uploaded: [], anchor: anchor, completes: completes, generation: generation)
        try save(entry)
        return entry
    }

    func pending() -> [Entry] {
        let dir = root.appendingPathComponent("pending")
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Entry.self, from: $0) } }
            .map { var e = $0; e.generation = generation; return e }
    }

    func batchData(_ id: String) -> Data? { try? Data(contentsOf: batchURL(id)) }

    func markUploaded(_ entry: inout Entry, batchId: String) throws {
        guard entry.generation == generation else { return }
        entry.uploaded.append(batchId)
        try save(entry)
        try? fm.removeItem(at: batchURL(batchId))
    }

    /// Applies the entry's anchor/state change and removes it. Called only when fully uploaded.
    func complete(_ entry: Entry) throws {
        guard entry.generation == generation else { return }
        try update { s in
            if let anchor = entry.anchor { s.anchors[entry.typeId] = anchor }
            switch entry.completes {
            case .recentDone: s.recentDone.insert(entry.typeId)
            case .statsFull(let at): s.statsFullAt[entry.typeId] = at
            case .caughtUp: s.caughtUp.insert(entry.typeId)
            case .caughtUpMany(let ids): s.caughtUp.formUnion(ids)
            case .reconcileDone:
                s.caughtUp.insert(entry.typeId)
                s.reconcile[entry.typeId] = nil
            case .activityInitial: s.activityInitialDone = true
            case .correlationInitial: s.correlationInitialDone.insert(entry.typeId)
            case .profile(let hash): s.profileHash = hash
            case nil: break
            }
        }
        try? fm.removeItem(at: pendingURL(entry.id))
    }

    /// Drops an entry without applying its anchor or completion, so the data it carried is read again.
    func discard(_ entry: Entry) throws {
        guard entry.generation == generation else { return }
        for id in entry.batchIds { try? fm.removeItem(at: batchURL(id)) }
        try? fm.removeItem(at: pendingURL(entry.id))
    }

    /// Deletes everything (used by "Delete all my data").
    func reset() {
        generation += 1
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root.appendingPathComponent("batches"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("pending"), withIntermediateDirectories: true)
        state = State()
    }

    private func save(_ entry: Entry) throws {
        try write(JSONEncoder().encode(entry), to: pendingURL(entry.id))
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func batchURL(_ id: String) -> URL { root.appendingPathComponent("batches/\(id).ndjson.gz") }
    private func pendingURL(_ id: String) -> URL { root.appendingPathComponent("pending/\(id).json") }
}
