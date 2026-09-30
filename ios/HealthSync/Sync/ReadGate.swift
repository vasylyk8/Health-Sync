import Foundation

/// Limits how many workouts are read from HealthKit at the same time, across all groups, and lets the
/// limit change while reading (see `ReadTuner`).
final class ReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = max(1, limit) }

    var currentLimit: Int { lock.withLock { limit } }

    func setLimit(_ n: Int) {
        let wake: [CheckedContinuation<Void, Never>] = lock.withLock {
            limit = max(1, n)
            return takeWaiters()
        }
        wake.forEach { $0.resume() }
    }

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let run: Bool = lock.withLock {
                if inFlight < limit {
                    inFlight += 1
                    return true
                }
                waiters.append(c)
                return false
            }
            if run { c.resume() }
        }
    }

    func release() {
        let wake: [CheckedContinuation<Void, Never>] = lock.withLock {
            inFlight -= 1
            return takeWaiters()
        }
        wake.forEach { $0.resume() }
    }

    /// Call with the lock held: hands free slots to the oldest waiters.
    private func takeWaiters() -> [CheckedContinuation<Void, Never>] {
        var out: [CheckedContinuation<Void, Never>] = []
        while inFlight < limit, !waiters.isEmpty {
            inFlight += 1
            out.append(waiters.removeFirst())
        }
        return out
    }
}

/// Finds the fastest number of parallel reads on this iPhone: measures work done per second over windows of
/// completed reads and moves the limit up while it helps, back when it hurts, and holds at a plateau.
final class ReadTuner: @unchecked Sendable {
    static let defaultMinLimit = 4
    static let defaultMaxLimit = 32

    private let minLimit: Int
    private let maxLimit: Int
    private let step: Int
    private let windowSize: Int
    private let current: @Sendable () -> Int
    private let apply: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var windowStart = Date()
    private var windowCount = 0
    private var lastRate: Double?
    private var direction = 1
    private var holdWindows = 0

    init(current: @escaping @Sendable () -> Int, apply: @escaping @Sendable (Int) -> Void, minLimit: Int, maxLimit: Int, step: Int, windowSize: Int) {
        self.current = current
        self.apply = apply
        self.minLimit = minLimit
        self.maxLimit = maxLimit
        self.step = step
        self.windowSize = windowSize
    }

    convenience init(gate: ReadGate) {
        self.init(current: { gate.currentLimit }, apply: { gate.setLimit($0) }, minLimit: Self.defaultMinLimit, maxLimit: Self.defaultMaxLimit, step: 4, windowSize: 24)
    }

    /// Call once per finished unit of work (a workout read).
    func completed() {
        let newLimit: Int? = lock.withLock {
            windowCount += 1
            guard windowCount >= windowSize else { return nil }
            let elapsed = max(Date().timeIntervalSince(windowStart), 0.001)
            let rate = Double(windowCount) / elapsed
            windowStart = Date()
            windowCount = 0
            return adjust(rate: rate, current: current())
        }
        if let newLimit {
            apply(newLimit)
            SyncTiming.shared.set("read.limit", newLimit)
        }
    }

    /// Lock held. Returns the new limit, or nil to keep it.
    private func adjust(rate: Double, current: Int) -> Int? {
        if holdWindows > 0 {
            holdWindows -= 1
            if holdWindows == 0 { direction = 1 }
            lastRate = rate
            return nil
        }
        defer { lastRate = rate }
        guard let previous = lastRate else { return clamp(current + step) }
        if rate > previous * 1.10 {
            return clamp(current + direction * step)
        } else if rate < previous * 0.90 {
            direction = -direction
            return clamp(current + direction * step)
        }
        holdWindows = 4
        return nil
    }

    private func clamp(_ n: Int) -> Int { min(max(n, minLimit), maxLimit) }
}
