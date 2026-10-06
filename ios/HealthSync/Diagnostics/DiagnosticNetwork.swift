import Foundation

protocol DiagnosticTransferReporting: Uploader { func transferSummary() -> String }

final class DiagnosticHTTPMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Double] = [:]
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        func seconds(_ a: Date?, _ b: Date?) -> Double { guard let a, let b else { return 0 }; return max(0, b.timeIntervalSince(a)) }
        lock.withLock {
            values["transactions", default: 0] += Double(metrics.transactionMetrics.count)
            for m in metrics.transactionMetrics {
                values["dnsSeconds", default: 0] += seconds(m.domainLookupStartDate, m.domainLookupEndDate)
                values["connectSeconds", default: 0] += seconds(m.connectStartDate, m.connectEndDate)
                values["tlsSeconds", default: 0] += seconds(m.secureConnectionStartDate, m.secureConnectionEndDate)
                values["requestSeconds", default: 0] += seconds(m.requestStartDate, m.requestEndDate)
                values["responseWaitSeconds", default: 0] += seconds(m.requestEndDate, m.responseStartDate)
                values["responseSeconds", default: 0] += seconds(m.responseStartDate, m.responseEndDate)
                values["reusedConnections", default: 0] += m.isReusedConnection ? 1 : 0
            }
        }
    }
    var snapshot: [String: Double] { lock.withLock { values } }
}
