import Foundation

enum IPServiceError: Error, Sendable, Equatable {
    case offline
    case timeout
    case http(statusCode: Int)
    case decoding(message: String)
    case transport(message: String)
    case cancelled

    var userDescription: String {
        switch self {
        case .offline:
            String(localized: "No network connection.")
        case .timeout:
            // Generic "IP lookup" rather than naming a specific provider:
            // since v0.33.0 the request flows through a fallback chain
            // (FallbackChainProvider), so the originating timeout could
            // be from either ipwho.is or ip.guide — naming one in the
            // user-facing message would be wrong half the time.
            String(localized: "The IP lookup request timed out.")
        case .http(let code):
            String(localized: "The IP lookup service returned an error (\(code)).")
        case .decoding:
            String(localized: "Got an unexpected response from the IP lookup service.")
        case .transport(let msg):
            // No trailing period — `URLError.localizedDescription`
            // already ends in "." so appending another produces
            // "fail..".
            String(localized: "Network error: \(msg)")
        case .cancelled:
            String(localized: "Request cancelled.")
        }
    }

    static func from(_ error: Error) -> IPServiceError {
        if let ipError = error as? IPServiceError { return ipError }
        if error is CancellationError { return .cancelled }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut: return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff:
                return .offline
            case NSURLErrorCancelled: return .cancelled
            default: return .transport(message: nsError.localizedDescription)
            }
        }
        return .transport(message: error.localizedDescription)
    }
}
