import Foundation

/// The phone always uses two reads; diagnostic builds can compare other widths.
enum DailyMetricConcurrency {
    static let productionWidth = 2
    static var width: Int {
        if let width = PhoneSyncComparisonContext.width { return width }
        #if DEBUG
        return DailyMetricExperiment.width
        #else
        return productionWidth
        #endif
    }
}

#if DEBUG
enum DailyMetricExperiment {
    @TaskLocal static var width = DailyMetricConcurrency.productionWidth
}
#endif

enum DailyMetricCollectionError: Error { case invalidIndex, duplicateIndex, missingResult }

/// Only the parent task owns these slots. Completion count alone never establishes completeness.
struct DailyMetricSlots<Value: Sendable> {
    private(set) var values: [Result<Value, Error>?]
    init(count: Int) { values = Array(repeating: nil, count: count) }
    mutating func record(index: Int, result: Result<Value, Error>) throws {
        guard values.indices.contains(index) else { throw DailyMetricCollectionError.invalidIndex }
        guard values[index] == nil else { throw DailyMetricCollectionError.duplicateIndex }
        values[index] = result
    }
    func complete() throws -> [Result<Value, Error>] {
        guard values.allSatisfy({ $0 != nil }) else { throw DailyMetricCollectionError.missingResult }
        return values.map { $0! }
    }
}

enum DailyMetricReads {
    static func collect<Input: Sendable, Value: Sendable>(
        _ inputs: [Input], width: Int,
        read: @escaping @Sendable (Input) async throws -> Value
    ) async throws -> [Result<Value, Error>] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Result<Value, Error>).self) { group in
            var slots = DailyMetricSlots<Value>(count: inputs.count)
            let firstCount = min(max(1, width), inputs.count)
            // Each task captures a distinct immutable index and input; no nested scheduling closure.
            for index in 0..<firstCount {
                let input = inputs[index]
                group.addTask { [index, input] in
                    try Task.checkCancellation()
                    do { return (index, .success(try await read(input))) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (index, .failure(error)) }
                }
            }
            var next = firstCount
            while let (index, result) = try await group.next() {
                try Task.checkCancellation()
                try slots.record(index: index, result: result)
                if next < inputs.count {
                    let index = next
                    let input = inputs[index]
                    next += 1
                    group.addTask { [index, input] in
                        try Task.checkCancellation()
                        do { return (index, .success(try await read(input))) }
                        catch is CancellationError { throw CancellationError() }
                        catch { return (index, .failure(error)) }
                    }
                }
            }
            try Task.checkCancellation()
            return try slots.complete()
        }
    }
}
