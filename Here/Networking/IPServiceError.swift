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
            String(localized: "The request to ip.guide timed out.")
        case .http(let code):
            String(localized: "ip.guide returned an error (\(code)).")
        case .decoding:
            String(localized: "Got an unexpected response from ip.guide.")
        case .transport(let msg):
            String(localized: "Network error: \(msg).")
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
