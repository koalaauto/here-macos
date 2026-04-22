import Foundation

enum IPState: Sendable {
    case idle
    case loading(cached: IPDataModel?)
    case loaded(IPDataModel, fetchedAt: Date)
    case error(IPServiceError, cached: IPDataModel?, fetchedAt: Date?)

    var model: IPDataModel? {
        switch self {
        case .idle: return nil
        case .loading(let cached): return cached
        case .loaded(let model, _): return model
        case .error(_, let cached, _): return cached
        }
    }

    var fetchedAt: Date? {
        switch self {
        case .idle, .loading: return nil
        case .loaded(_, let date): return date
        case .error(_, _, let date): return date
        }
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var error: IPServiceError? {
        if case .error(let err, _, _) = self { return err }
        return nil
    }
}
