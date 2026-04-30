import Foundation

/// How often the app polls GitHub for a newer release.
///
/// Three options is deliberate: `.never` for users who prefer to
/// upgrade manually, `.daily` (default) so update notifications
/// surface within ~24 h of a release, `.weekly` for users who want
/// the absolute minimum chatter. We don't offer a finer cadence —
/// GitHub's unauthenticated API is 60 req/hr per client IP and
/// hourly polling would burn that budget for zero user benefit on a
/// project that ships every few weeks at most.
enum UpdateCheckFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case never
    case daily
    case weekly

    var id: String { rawValue }

    /// Minimum interval between automatic checks. `nil` means automatic
    /// checks are disabled — the user can still trigger a check via the
    /// "Check now" button in About.
    var interval: TimeInterval? {
        switch self {
        case .never:  nil
        case .daily:  24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        }
    }

    var localizedTitle: String {
        switch self {
        case .never:  String(localized: "Never")
        case .daily:  String(localized: "Once a day")
        case .weekly: String(localized: "Once a week")
        }
    }
}
