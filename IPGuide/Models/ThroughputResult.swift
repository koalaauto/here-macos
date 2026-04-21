import Foundation

/// One completed throughput measurement. Persisted as the "last result" so
/// reopening the popover shows the prior numbers immediately instead of
/// blanking out.
struct ThroughputResult: Codable, Sendable, Equatable {
    let downloadMbps: Double
    let uploadMbps: Double
    let testedAt: Date
}

/// State machine for the on-demand throughput probe.
enum ThroughputStatus: Sendable, Equatable {
    case idle(lastResult: ThroughputResult?)
    /// Probing is in progress. `startedAt` + `estimatedDuration` drive the
    /// progress bar animation; no live Mbps for v1.
    case probing(
        direction: Direction,
        startedAt: Date,
        estimatedDuration: TimeInterval,
        lastResult: ThroughputResult?
    )
    case failed(reason: String, lastResult: ThroughputResult?)

    enum Direction: String, Sendable, Equatable {
        case download
        case upload
    }

    var lastResult: ThroughputResult? {
        switch self {
        case .idle(let r),
             .failed(_, let r),
             .probing(_, _, _, let r):
            return r
        }
    }

    var isRunning: Bool {
        if case .probing = self { return true }
        return false
    }
}
