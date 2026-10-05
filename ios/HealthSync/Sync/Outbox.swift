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
        case caughtUp
        /// A status batch confirmed these types are fully synced.
        case caughtUpMany([String])
        case reconcileDone
        /// A full recompute of the daily context reached `Date`.
        case dailyFull(Date)
        /// The raw data of this workout (its HealthKit uuid) is on the server.
        case detailDone(String)
        /// The raw data of these workouts (several per upload) is on the server.
        case detailsDone([String])
        /// Daily rows of this chunk (key) with this content hash are on the server.
        case dailyHash(key: String, hash: String)
        /// Hourly series are on the server up to `through`; `at` (when set) marks the pass as finished.
        case hourly(through: Date, at: Date?)
        /// The profile entry was sent at this time.
        case profileAt(Date)
        /// The medication list was sent at this time.
        case medicationsAt(Date)
    }

    struct State: Codable, Equatable {
        /// 1 = the app that synced every Health type; 2 = workouts and daily context only.
        static let currentSchema = 2

        var schemaVersion = State.currentSchema
        var anchors: [String: Data] = [:]
        var seq: [String: Int64] = [:]
        var recentDone: Set<String> = []
        var caughtUp: Set<String> = []
        var reconcile: [String: String] = [:]
        var dailyFullAt: Date?
        /// Workouts whose raw data has been uploaded.
        var detailsDone: Set<String> = []
        /// Workouts found on this iPhone at the last check (for progress).
        var workoutTotal = 0
        var lastSyncAt: Date?
        /// Content hash of the daily rows last sent per chunk ("full|type|chunkStart" or "inc|type"), so unchanged rows are not sent again.
        var dailyHashes: [String: String] = [:]
        /// Hourly series: uploaded through this time, and when the last complete pass ended.
        var hourlyThrough: Date?
        var hourlyAt: Date?
        var profileAt: Date?
        var medicationsAt: Date?
        /// Version of the daily-rows logic that produced what was sent; a newer app re-reads the whole history once.
        var dailyVersion = 0
        /// Same for the hourly series.
        var hourlyVersion = 0
        /// Version of workout-detail extraction; a newer app re-reads each workout once when new streams become reachable.
        var detailVersion = 1

        init() {}

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, anchors, seq, recentDone, caughtUp, reconcile, dailyFullAt, detailsDone, workoutTotal, lastSyncAt
            case dailyHashes, hourlyThrough, hourlyAt, profileAt, medicationsAt, dailyVersion, hourlyVersion, detailVersion
        }

        /// Tolerant decoding: a state file written by an older app version (missing or extra keys)
        /// still loads; a missing schemaVersion means version 1.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            anchors = try c.decodeIfPresent([String: Data].self, forKey: .anchors) ?? [:]
            seq = try c.decodeIfPresent([String: Int64].self, forKey: .seq) ?? [:]
            recentDone = try c.decodeIfPresent(Set<String>.self, forKey: .recentDone) ?? []
            caughtUp = try c.decodeIfPresent(Set<String>.self, forKey: .caughtUp) ?? []
            reconcile = try c.decodeIfPresent([String: String].self, forKey: .reconcile) ?? [:]
            dailyFullAt = try c.decodeIfPresent(Date.self, forKey: .dailyFullAt)
            detailsDone = try c.decodeIfPresent(Set<String>.self, forKey: .detailsDone) ?? []
            workoutTotal = try c.decodeIfPresent(Int.self, forKey: .workoutTotal) ?? 0
            lastSyncAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncAt)
            dailyHashes = try c.decodeIfPresent([String: String].self, forKey: .dailyHashes) ?? [:]
            hourlyThrough = try c.decodeIfPresent(Date.self, forKey: .hourlyThrough)
            hourlyAt = try c.decodeIfPresent(Date.self, forKey: .hourlyAt)
            profileAt = try c.decodeIfPresent(Date.self, forKey: .profileAt)
            medicationsAt = try c.decodeIfPresent(Date.self, forKey: .medicationsAt)
            dailyVersion = try c.decodeIfPresent(Int.self, forKey: .dailyVersion) ?? 0
            hourlyVersion = try c.decodeIfPresent(Int.self, forKey: .hourlyVersion) ?? 0
            detailVersion = try c.decodeIfPresent(Int.self, forKey: .detailVersion) ?? 0
        }
    }

    let root: URL
    private(set) var state: State
    /// Bumped by `reset()`. Entries read or created earlier must not write state afterwards
    /// (an upload that was in flight when the user deleted everything).
    private var generation = 0
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
        let fm = FileManager.default
        try? fm.createDirectory(at: root.appendingPathComponent("batches"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: root.appendingPathComponent("pending"), withIntermediateDirectories: true)
        let stateURL = root.appendingPathComponent("state.json")
        if let data = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode(State.self, from: data) {
            if old.schemaVersion < State.currentSchema {
                // Upgrade from the app that synced every Health type: only workouts and daily context
                // sync now, and every workout is re-read with its full detail. Sequence numbers are kept
                // (the server keeps the highest one per record, so a reset would let old rows win);
                // queued batches of the old format are dropped.
                var fresh = State()
                fresh.seq = old.seq
                for dir in ["batches", "pending"] {
                    let url = root.appendingPathComponent(dir)
                    for f in (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: f) }
                }
                if let encoded = try? JSONEncoder().encode(fresh) {
                    try? encoded.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                }
                state = fresh
            } else {
                state = old
            }
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

    /// Sequence numbers start at the current time in milliseconds and then count up. The server keeps the row with the
    /// highest number per record, so a fresh install (empty state) must start above everything an earlier install
    /// sent; otherwise its complete rows lose to the old, possibly incomplete ones.
    private static let clockEra: Int64 = 1_000_000_000_000
    static func seqFloor(_ now: Date = Date()) -> Int64 { Int64(now.timeIntervalSince1970 * 1000) }

    /// Reserves the next sequence number for a type (persisted before use, so it never repeats).
    func nextSeq(_ typeId: String) throws -> Int64 {
        try reserveSeqs(typeId, count: 1)
    }

    /// Reserves `count` consecutive sequence numbers for a type with one state write; returns the first.
    func reserveSeqs(_ typeId: String, count: Int) throws -> Int64 {
        var first: Int64 = 0
        try update { s in
            var last = s.seq[typeId] ?? 0
            // A counter below the clock era (fresh state, or an older app's) jumps to the clock once, then just counts up.
            if last < Self.clockEra { last = max(last, Self.seqFloor()) }
            first = last + 1
            s.seq[typeId] = first + Int64(max(1, count)) - 1
        }
        return first
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
            case .caughtUp: s.caughtUp.insert(entry.typeId)
            case .caughtUpMany(let ids): s.caughtUp.formUnion(ids)
            case .reconcileDone:
                s.caughtUp.insert(entry.typeId)
                s.reconcile[entry.typeId] = nil
            case .dailyFull(let at): s.dailyFullAt = at
            case .detailDone(let id): s.detailsDone.insert(id)
            case .detailsDone(let ids): s.detailsDone.formUnion(ids)
            case .dailyHash(let key, let hash): s.dailyHashes[key] = hash
            case .hourly(let through, let at):
                s.hourlyThrough = max(s.hourlyThrough ?? through, through)
                if let at { s.hourlyAt = at }
            case .profileAt(let date): s.profileAt = date
            case .medicationsAt(let date): s.medicationsAt = date
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

    // MARK: Progress kept across Log out

    /// A copy of an account's sync progress, kept outside `root` (which `reset()` empties) while that account is logged out.
    private var savedDir: URL { root.deletingLastPathComponent().appendingPathComponent("saved-\(root.lastPathComponent)", isDirectory: true) }
    private func savedURL(_ account: String) -> URL { savedDir.appendingPathComponent(account.filter { $0.isLetter || $0.isNumber } + ".json") }

    /// Keeps this account's progress (what was already sent, and where each type stopped) so that signing back in to the
    /// same account only syncs what is new. Not kept while anything is still waiting to upload: the anchors could be
    /// ahead of data the server has not received.
    @discardableResult
    func saveProgress(account: String) -> Bool {
        guard pending().isEmpty, !state.anchors.isEmpty || !state.caughtUp.isEmpty, let data = try? JSONEncoder().encode(state) else { return false }
        try? fm.createDirectory(at: savedDir, withIntermediateDirectories: true)
        do { try write(data, to: savedURL(account)); return true } catch { return false }
    }

    /// Puts back the progress kept for `account`, if any.
    @discardableResult
    func restoreProgress(account: String) -> Bool {
        guard let data = try? Data(contentsOf: savedURL(account)),
              let saved = try? JSONDecoder().decode(State.self, from: data),
              saved.schemaVersion == State.currentSchema else { return false }
        do { try update { $0 = saved }; return true } catch { return false }
    }

    func deleteSavedProgress() { try? fm.removeItem(at: savedDir) }

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
