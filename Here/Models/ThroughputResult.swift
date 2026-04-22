import Foundation

/// One completed download-throughput measurement. Persisted as the "last
/// result" so reopening the popover shows the prior reading immediately.
struct ThroughputResult: Codable, Sendable, Equatable {
    let downloadMbps: Double
    let testedAt: Date
}

/// State machine for the on-demand throughput probe.
///
/// Intentional UX: during a probe, the number blanks to "…" and fills in
/// once the live Mbps estimate arrives; the progress bar is real transfer
/// progress (bytes received / Content-Length). Stale previous-test values
/// are NOT shown while a fresh probe is in flight.
enum ThroughputStatus: Sendable, Equatable {
    case idle(lastResult: ThroughputResult?)

    /// Probing is in progress.
    /// - `liveMbps` — rolling Mbps estimate from the delegate (≈ 5 Hz).
    ///   `nil` for the first ~150 ms before a stable reading exists.
    /// - `liveProgress` (0 … 1) — real transfer progress derived from
    ///   bytes received and the response's `Content-Length`.
    case probing(liveMbps: Double?, liveProgress: Double)

    case failed(reason: String, lastResult: ThroughputResult?)

    /// The most recent *completed* result, if any. During `.probing` this
    /// is intentionally nil so the UI doesn't surface stale numbers.
    var lastResult: ThroughputResult? {
        switch self {
        case .idle(let r), .failed(_, let r): r
        case .probing:                         nil
        }
    }

    var isRunning: Bool {
        if case .probing = self { return true }
        return false
    }
}
