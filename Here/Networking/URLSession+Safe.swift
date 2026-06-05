import Foundation

extension URLSession {
    /// Drop-in replacement for `data(for:)` that survives an Obj-C
    /// `NSException` thrown from URLSession's internal task creation
    /// (`-[__NSURLSessionLocal taskForClassInfo:]` and similar).
    ///
    /// The system `data(for:)` does **not** catch these. NSException
    /// is not a Swift `Error`, so Swift's `do/catch` cannot intercept
    /// it — the exception bubbles up to `objc_terminate` and the
    /// process dies with `SIGABRT`. We hit this in v0.32.0 (latency
    /// probe path on macOS 26.5 under a utun transparent proxy):
    /// the app crashed within ~900 ms of launch with the exception
    /// rising through `LatencyService.performProbe`.
    ///
    /// `safeData(for:)` routes task construction through the
    /// `HereSafeDataTask` Obj-C barrier (see `HereURLSessionSafe.h`),
    /// which converts the exception to an `NSError` that `catch` can
    /// see. Behaviour is otherwise identical to `data(for:)`:
    /// supports task cancellation via `withTaskCancellationHandler`,
    /// and emits `URLError.cancelled` from the completion handler
    /// when the Swift task is cancelled mid-flight.
    /// Delegate-style task creation guarded by the same `@try`/`@catch`
    /// barrier as `safeData(for:)`. Use this for `URLSessionDataDelegate`-
    /// backed flows (e.g. `ThroughputService.SpeedProbe`) where you need
    /// the raw `URLSessionDataTask` to call `.resume()` yourself.
    ///
    /// Throws an `NSError` (in `HereURLSessionSafeErrorDomain`) if the
    /// underlying `dataTask(with:)` would have thrown an `NSException`.
    func safeDataTask(with request: URLRequest) throws -> URLSessionDataTask {
        var outError: NSError?
        let task = HereSafeDataTaskWithoutCompletion(self, request, &outError)
        if let outError { throw outError }
        guard let task else { throw URLError(.unknown) }
        return task
    }

    func safeData(for request: URLRequest) async throws -> (Data, URLResponse) {
        let storage = SafeTaskStorage()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                var outError: NSError?
                let task = HereSafeDataTask(self, request, { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let data, let response {
                        continuation.resume(returning: (data, response))
                    } else {
                        continuation.resume(throwing: URLError(.unknown))
                    }
                }, &outError)
                if let outError {
                    continuation.resume(throwing: outError)
                    return
                }
                guard let task else {
                    // Shouldn't happen — outError is set whenever the
                    // shim returns nil — but be defensive.
                    continuation.resume(throwing: URLError(.unknown))
                    return
                }
                storage.arm(task)
                task.resume()
            }
        } onCancel: {
            storage.cancel()
        }
    }
}

/// Thread-safe slot bridging `withTaskCancellationHandler`'s `onCancel`
/// closure to the `URLSessionDataTask` created inside the continuation
/// block. The two run on independent contexts; we have to coordinate
/// the "task created vs. task cancelled" race ourselves.
private final class SafeTaskStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    /// Park the task for later cancellation. If `cancel()` already
    /// fired (Swift task was cancelled before our URLSession task
    /// existed), cancel `t` immediately so its completion handler
    /// fires with `URLError.cancelled` and resumes the continuation.
    func arm(_ t: URLSessionDataTask) {
        lock.lock(); defer { lock.unlock() }
        if cancelled {
            t.cancel()
        } else {
            task = t
        }
    }

    /// Mark cancelled and cancel any task armed so far. Idempotent.
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}
