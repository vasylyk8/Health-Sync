import Foundation
import HealthKit

/// Reads Apple Health through HealthKit and converts objects to batch records.
final class HealthKitSource: HealthSource, @unchecked Sendable {
    private let store = HKHealthStore()

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAuthorization(types: [SyncType]) async throws {
        try await store.requestAuthorization(toShare: [], read: HealthTypes.readPermissions(for: types))
    }

    // MARK: Samples

    func samples(_ type: SyncType, from: Date, to: Date) async throws -> [Record] {
        guard let sampleType = type.sampleType else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let samples: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(q)
        }
        return try await encode(samples, as: type)
    }

    func anchoredPage(_ type: SyncType, anchor: Data?, limit: Int) async throws -> AnchoredPage {
        guard let sampleType = type.sampleType else { return AnchoredPage(records: [], newAnchor: anchor, objectCount: 0) }
        let hkAnchor = anchor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0) }
        let (samples, deleted, newAnchor): ([HKSample], [HKDeletedObject], HKQueryAnchor?) = try await withCheckedThrowingContinuation { cont in
            let q = HKAnchoredObjectQuery(type: sampleType, predicate: nil, anchor: hkAnchor, limit: limit) { _, samples, deleted, newAnchor, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (samples ?? [], deleted ?? [], newAnchor)) }
            }
            store.execute(q)
        }
        var records = try await encode(samples, as: type)
        records.append(contentsOf: deleted.map { ["k": "d", "id": .string($0.uuid.uuidString)] })
        let anchorData = newAnchor.flatMap { try? NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
        return AnchoredPage(records: records, newAnchor: anchorData, objectCount: samples.count + deleted.count)
    }

    func earliestSampleDate(_ type: SyncType) async throws -> Date? {
        guard let sampleType = type.sampleType else { return nil }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        return try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sampleType, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results?.first?.startDate) }
            }
            store.execute(q)
        }
    }

    // MARK: Statistics

    func hourlyStats(_ type: SyncType, from: Date, to: Date) async throws -> [Record] {
        guard let qt = type.quantityType, let unit = type.unit, case .quantity(let cumulative) = type.kind else { return [] }
        let options: HKStatisticsOptions = cumulative ? .cumulativeSum : [.discreteAverage, .discreteMin, .discreteMax]
        let cal = Calendar(identifier: .gregorian)
        let anchorDate = cal.dateInterval(of: .hour, for: from)?.start ?? from
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: [])
        let unitName = unitLabel(type)
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { cont in
            let q = HKStatisticsCollectionQuery(quantityType: qt, quantitySamplePredicate: predicate, options: options, anchorDate: anchorDate, intervalComponents: DateComponents(hour: 1))
            q.initialResultsHandler = { _, collection, error in
                if let collection { cont.resume(returning: collection) } else { cont.resume(throwing: error ?? HealthSourceError.noResults) }
            }
            store.execute(q)
        }
        var out: [Record] = []
        collection.enumerateStatistics(from: from, to: to) { stats, _ in
            func add(_ agg: String, _ q: HKQuantity?) {
                guard let q else { return }
                out.append(["k": "h", "s": stats.startDate.ms, "e": stats.endDate.ms, "agg": .string(agg), "v": .double(q.doubleValue(for: unit)), "u": .string(unitName)])
            }
            if cumulative {
                add("sum", stats.sumQuantity())
            } else {
                add("avg", stats.averageQuantity())
                add("min", stats.minimumQuantity())
                add("max", stats.maximumQuantity())
            }
        }
        return out
    }

    // MARK: Activity summaries, correlations, profile

    func activitySummaries(from: Date, to: Date) async throws -> [Record] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        var start = cal.dateComponents([.era, .year, .month, .day], from: from)
        var end = cal.dateComponents([.era, .year, .month, .day], from: to)
        start.calendar = cal
        end.calendar = cal
        let predicate = HKQuery.predicate(forActivitySummariesBetweenStart: start, end: end)
        let summaries: [HKActivitySummary] = try await withCheckedThrowingContinuation { cont in
            let q = HKActivitySummaryQuery(predicate: predicate) { _, summaries, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: summaries ?? []) }
            }
            store.execute(q)
        }
        return summaries.compactMap { s in
            let dc = s.dateComponents(for: cal)
            guard let y = dc.year, let m = dc.month, let d = dc.day else { return nil }
            var r: Record = ["k": "a", "day": .string(String(format: "%04d-%02d-%02d", y, m, d))]
            r["ae"] = .double(s.activeEnergyBurned.doubleValue(for: .kilocalorie()))
            r["aeg"] = .double(s.activeEnergyBurnedGoal.doubleValue(for: .kilocalorie()))
            r["ex"] = .double(s.appleExerciseTime.doubleValue(for: .minute()))
            r["st"] = .double(s.appleStandHours.doubleValue(for: .count()))
            r["mv"] = .double(s.appleMoveTime.doubleValue(for: .minute()))
            if let g = s.exerciseTimeGoal { r["exg"] = .double(g.doubleValue(for: .minute())) }
            if let g = s.standHoursGoal { r["stg"] = .double(g.doubleValue(for: .count())) }
            return r
        }
    }

    func correlations(_ type: SyncType, from: Date, to: Date) async throws -> [Record] {
        guard let sampleType = type.sampleType else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: from, end: to, options: .strictStartDate)
        let results: [HKSample] = try await withCheckedThrowingContinuation { cont in
            let q = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, results, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: results ?? []) }
            }
            store.execute(q)
        }
        let quantityTypes = Dictionary(uniqueKeysWithValues: HealthTypes.resolve(HealthTypes.loadCoverage()).compactMap { t in t.quantityType.map { ($0.identifier, t) } })
        return results.compactMap { sample in
            guard let c = sample as? HKCorrelation else { return nil }
            var r = base(c, kind: "x")
            r["ct"] = .string(c.correlationType.identifier)
            r["items"] = .array(c.objects.compactMap { obj in
                guard let q = obj as? HKQuantitySample, let t = quantityTypes[q.quantityType.identifier], let unit = t.unit else { return nil }
                return .object(["id": .string(q.uuid.uuidString), "t": .string(q.quantityType.identifier), "v": .double(q.quantity.doubleValue(for: unit)), "u": .string(unitLabel(t))])
            })
            return r
        }
    }

    func profile() -> Record? {
        var r: Record = ["k": "p"]
        if let dob = try? store.dateOfBirthComponents(), let y = dob.year, let m = dob.month, let d = dob.day {
            r["dob"] = .string(String(format: "%04d-%02d-%02d", y, m, d))
        }
        if let sex = try? store.biologicalSex().biologicalSex {
            let names: [HKBiologicalSex: String] = [.female: "female", .male: "male", .other: "other"]
            r["sex"] = .string(names[sex] ?? "notSet")
        }
        if let blood = try? store.bloodType().bloodType {
            let names: [HKBloodType: String] = [.aPositive: "A+", .aNegative: "A-", .bPositive: "B+", .bNegative: "B-", .abPositive: "AB+", .abNegative: "AB-", .oPositive: "O+", .oNegative: "O-"]
            r["blood"] = .string(names[blood] ?? "notSet")
        }
        if let skin = try? store.fitzpatrickSkinType().skinType { r["skin"] = .int(Int64(skin.rawValue)) }
        if let wc = try? store.wheelchairUse().wheelchairUse { r["wheelchair"] = .string(wc == .yes ? "yes" : wc == .no ? "no" : "notSet") }
        if let mode = try? store.activityMoveMode().activityMoveMode { r["activityMoveMode"] = .string(mode == .appleMoveTime ? "moveTime" : "activeEnergy") }
        return r.count > 1 ? r : nil
    }

    // MARK: Background delivery

    func observeChanges(types: [SyncType], onChange: @escaping @Sendable (SyncType, @escaping @Sendable () -> Void) -> Void) {
        for t in types where t.isAnchored {
            guard let sampleType = t.sampleType else { continue }
            let q = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completion, error in
                if error != nil {
                    completion()
                    return
                }
                onChange(t) { completion() }
            }
            store.execute(q)
            store.enableBackgroundDelivery(for: sampleType, frequency: .hourly) { _, _ in }
        }
    }

    // MARK: Encoding

    private func encode(_ samples: [HKSample], as type: SyncType) async throws -> [Record] {
        var out: [Record] = []
        out.reserveCapacity(samples.count)
        for sample in samples {
            switch sample {
            case let q as HKQuantitySample:
                guard let unit = type.unit else { continue }
                if case .quantity(cumulative: false) = type.kind, q.count > 1 {
                    out.append(contentsOf: try await expandSeries(q, type: type, unit: unit))
                } else {
                    var r = base(q, kind: "s")
                    r["v"] = .double(q.quantity.doubleValue(for: unit))
                    r["u"] = .string(unitLabel(type))
                    if q.count > 1 { r["n"] = .int(Int64(q.count)) }
                    out.append(r)
                }
            case let c as HKCategorySample:
                var r = base(c, kind: "s")
                r["c"] = .int(Int64(c.value))
                out.append(r)
            case let w as HKWorkout:
                out.append(workout(w))
            case let ecg as HKElectrocardiogram:
                out.append(try await electrocardiogram(ecg))
            case let hb as HKHeartbeatSeriesSample:
                out.append(try await heartbeat(hb))
            case let a as HKAudiogramSample:
                var r = base(a, kind: "s")
                r["points"] = .array(a.sensitivityPoints.map { p in
                    var o: [String: RecordValue] = ["hz": .double(p.frequency.doubleValue(for: .hertz()))]
                    if let l = p.leftEarSensitivity { o["left_dBHL"] = .double(l.doubleValue(for: .decibelHearingLevel())) }
                    if let r = p.rightEarSensitivity { o["right_dBHL"] = .double(r.doubleValue(for: .decibelHearingLevel())) }
                    return .object(o)
                })
                out.append(r)
            default:
                if #available(iOS 18.0, *), let m = sample as? HKStateOfMind {
                    var r = base(m, kind: "s")
                    r["v"] = .double(m.valence)
                    r["c"] = .int(Int64(m.kind.rawValue))
                    r["labels"] = .array(m.labels.map { .int(Int64($0.rawValue)) })
                    r["associations"] = .array(m.associations.map { .int(Int64($0.rawValue)) })
                    out.append(r)
                }
            }
        }
        return out
    }

    private func base(_ s: HKSample, kind: String) -> Record {
        var r: Record = ["k": .string(kind), "id": .string(s.uuid.uuidString), "s": s.startDate.ms, "e": s.endDate.ms]
        r["src"] = .string(s.sourceRevision.source.name)
        r["bid"] = .string(s.sourceRevision.source.bundleIdentifier)
        if let model = s.device?.model ?? s.device?.name { r["dev"] = .string(model) }
        if let tz = s.metadata?[HKMetadataKeyTimeZone] as? String { r["tz"] = .string(tz) }
        if let md = metadata(s.metadata) { r["md"] = md }
        return r
    }

    /// Keeps small scalar metadata values; drops anything else. Max ~2 KB.
    private func metadata(_ md: [String: Any]?) -> RecordValue? {
        guard let md, !md.isEmpty else { return nil }
        var out: [String: RecordValue] = [:]
        var size = 0
        for (key, value) in md.sorted(by: { $0.key < $1.key }) where key != HKMetadataKeyTimeZone {
            let v: RecordValue
            switch value {
            case let b as Bool: v = .bool(b)
            case let n as NSNumber: v = .double(n.doubleValue)
            case let s as String: v = .string(String(s.prefix(200)))
            case let d as Date: v = d.ms
            case let q as HKQuantity: v = .string(q.description)
            default: continue
            }
            size += key.count + 16
            if size > 2000 { break }
            out[String(key.prefix(100))] = v
        }
        return out.isEmpty ? nil : .object(out)
    }

    private func expandSeries(_ q: HKQuantitySample, type: SyncType, unit: HKUnit) async throws -> [Record] {
        guard let qt = type.quantityType else { return [] }
        let predicate = HKQuery.predicateForObject(with: q.uuid)
        let parent = base(q, kind: "s")
        let label = unitLabel(type)
        let points: [(Double, DateInterval)] = try await withCheckedThrowingContinuation { cont in
            var acc: [(Double, DateInterval)] = []
            let query = HKQuantitySeriesSampleQuery(quantityType: qt, predicate: predicate) { _, quantity, interval, _, done, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                if let quantity, let interval { acc.append((quantity.doubleValue(for: unit), interval)) }
                if done { cont.resume(returning: acc) }
            }
            store.execute(query)
        }
        if points.isEmpty {
            var r = parent
            r["v"] = .double(q.quantity.doubleValue(for: unit))
            r["u"] = .string(label)
            return [r]
        }
        return points.enumerated().map { i, p in
            var r = parent
            r["id"] = .string("\(q.uuid.uuidString)#\(i)")
            r["s"] = p.1.start.ms
            r["e"] = p.1.end.ms
            r["v"] = .double(p.0)
            r["u"] = .string(label)
            return r
        }
    }

    private func workout(_ w: HKWorkout) -> Record {
        var r = base(w, kind: "w")
        r["act"] = .int(Int64(w.workoutActivityType.rawValue))
        r["actName"] = .string(WorkoutNames.name(w.workoutActivityType))
        r["dur"] = .double(w.duration)
        if let energy = w.statistics(for: HKQuantityType(.activeEnergyBurned))?.sumQuantity() {
            r["en"] = .double(energy.doubleValue(for: .kilocalorie()))
        }
        let distanceTypes: [HKQuantityTypeIdentifier] = [.distanceWalkingRunning, .distanceCycling, .distanceSwimming, .distanceWheelchair, .distanceDownhillSnowSports]
        for id in distanceTypes {
            if let d = w.statistics(for: HKQuantityType(id))?.sumQuantity() {
                r["dist"] = .double(d.doubleValue(for: .meter()))
                break
            }
        }
        if let hr = w.statistics(for: HKQuantityType(.heartRate)) {
            let bpm = HKUnit.count().unitDivided(by: .minute())
            if let avg = hr.averageQuantity() { r["hrAvg"] = .double(avg.doubleValue(for: bpm)) }
            if let max = hr.maximumQuantity() { r["hrMax"] = .double(max.doubleValue(for: bpm)) }
        }
        if let events = w.workoutEvents, !events.isEmpty {
            r["ev"] = .array(events.prefix(500).map { e in
                .object(["t": e.dateInterval.start.ms, "type": .int(Int64(e.type.rawValue)), "dur": .double(e.dateInterval.duration)])
            })
        }
        if w.workoutActivities.count > 1 {
            r["acts"] = .array(w.workoutActivities.map { a in
                .object([
                    "s": a.startDate.ms, "e": (a.endDate ?? w.endDate).ms,
                    "act": .int(Int64(a.workoutConfiguration.activityType.rawValue)),
                    "actName": .string(WorkoutNames.name(a.workoutConfiguration.activityType)),
                ])
            })
        }
        return r
    }

    private func electrocardiogram(_ ecg: HKElectrocardiogram) async throws -> Record {
        var r = base(ecg, kind: "ecg")
        r["cls"] = .int(Int64(ecg.classification.rawValue))
        r["sym"] = .int(Int64(ecg.symptomsStatus.rawValue))
        if let hr = ecg.averageHeartRate { r["hr"] = .double(hr.doubleValue(for: .count().unitDivided(by: .minute()))) }
        if let hz = ecg.samplingFrequency { r["hz"] = .double(hz.doubleValue(for: .hertz())) }
        let volts: [Double] = try await withCheckedThrowingContinuation { cont in
            var acc: [Double] = []
            let q = HKElectrocardiogramQuery(ecg) { _, result in
                switch result {
                case .measurement(let m):
                    if let v = m.quantity(for: .appleWatchSimilarToLeadI) { acc.append(v.doubleValue(for: .voltUnit(with: .micro))) }
                case .done:
                    cont.resume(returning: acc)
                case .error(let error):
                    cont.resume(throwing: error)
                @unknown default:
                    break
                }
            }
            store.execute(q)
        }
        r["volt"] = .array(volts.map { .double(($0 * 10).rounded() / 10) })
        return r
    }

    private func heartbeat(_ series: HKHeartbeatSeriesSample) async throws -> Record {
        var r = base(series, kind: "hb")
        let beats: [RecordValue] = try await withCheckedThrowingContinuation { cont in
            var acc: [RecordValue] = []
            let q = HKHeartbeatSeriesQuery(heartbeatSeries: series) { _, time, gap, done, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                acc.append(.object(["t": .double((time * 1000).rounded()), "gap": .bool(gap)]))
                if done { cont.resume(returning: acc) }
            }
            store.execute(q)
        }
        r["beats"] = .array(beats)
        return r
    }

    private func unitLabel(_ type: SyncType) -> String {
        HealthTypes.loadCoverageUnits()[type.id] ?? type.unit?.unitString ?? ""
    }
}

enum HealthSourceError: Error {
    case noResults
}

extension HealthTypes {
    private static let unitsById: [String: String] = Dictionary(uniqueKeysWithValues: loadCoverage().compactMap { e in e.unit.map { (e.id, $0) } })
    /// Unit labels exactly as written in the coverage matrix (the server's canonical names).
    static func loadCoverageUnits() -> [String: String] { unitsById }
}
