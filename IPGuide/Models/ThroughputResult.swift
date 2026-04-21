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
///
/// Intentional UX: while a probe is in flight, the two speed numbers are
/// blanked out — we only fill in a direction's final value once that
/// direction's measurement finishes. So during the download phase: ↓ says
/// "…" (animating), ↑ says "…" (waiting); after download lands: ↓ shows the
/// fresh number, ↑ is now animating; when upload lands: both idle.
enum ThroughputStatus: Sendable, Equatable {
    case idle(lastResult: ThroughputResult?)

    /// Probing is in progress.
    /// - `phase` = which direction is currently being measured
    /// - `startedAt` + `estimatedDuration` drive the progress-bar animation
    ///   for the active direction
    /// - `completedDownloadMbps` is set to the just-measured download value
    ///   once the download phase finishes, so the UI can flip the download
    ///   block from "…" to the real reading while the upload phase runs
    case probing(
        phase: Direction,
        startedAt: Date,
        estimatedDuration: TimeInterval,
        completedDownloadMbps: Double?
    )

    case failed(reason: String, lastResult: ThroughputResult?)

    enum Direction: String, Sendable, Equatable {
        case download
        case upload
    }

    /// The most recent *completed* result, if any. During `.probing` this is
    /// intentionally nil so the UI doesn't surface stale numbers — each
    /// block fills in as its fresh reading arrives.
    var lastResult: ThroughputResult? {
        switch self {
        case .idle(let r), .failed(_, let r): r
        case .probing: nil
        }
    }

    var isRunning: Bool {
        if case .probing = self { return true }
        return false
    }
}
