import Foundation
import Testing

@testable import Here

/// Regression test for the v0.32.0 → v0.32.1 crash: an Obj-C `NSException`
/// thrown by `-[__NSURLSessionLocal taskForClassInfo:]` during task
/// creation escaped Swift's `do/catch` and killed the app with `SIGABRT`.
///
/// `URLSession+Safe.swift` routes task creation through the
/// `HereURLSessionSafe` Obj-C barrier (`@try`/`@catch`) which converts
/// the exception into an `NSError` that Swift `catch` can handle.
///
/// The most reliable way to provoke the underlying `NSException` from
/// pure user code is to call `dataTask(...)` on a URLSession that has
/// already been invalidated. Per Apple docs: "If you attempt to create
/// a task in a session that has been invalidated, a runtime error
/// occurs." (Read: NSException.) Pre-fix, this test crashed the test
/// process; post-fix, it throws a Swift `Error`.
@Suite("URLSession Safe wrapper")
struct URLSessionSafeTests {

    /// Provoke an NSException from task creation by using an invalidated
    /// session. The safe wrapper must NOT crash and MUST surface a
    /// Swift-catchable error.
    @Test("safeData(for:) on invalidated session throws instead of SIGABRT")
    func safeDataOnInvalidatedSession() async {
        let session = URLSession(configuration: .ephemeral)
        session.invalidateAndCancel()

        // Give the runtime a moment for the invalidation to land.
        try? await Task.sleep(nanoseconds: 50_000_000)

        let request = URLRequest(url: URL(string: "https://example.com")!)

        var caught: Error?
        do {
            _ = try await session.safeData(for: request)
            Issue.record("Expected safeData to throw on invalidated session, got a value.")
        } catch {
            caught = error
        }

        #expect(caught != nil)
        // Either the NSException path fires (HereURLSessionSafeErrorDomain)
        // or the session declines and surfaces URLError — both are
        // acceptable. The bug we're fixing is the process dying; either
        // throw-shape proves we didn't.
        if let nsError = caught as NSError? {
            let acceptableDomains: Set<String> = [
                "app.here-macos.URLSessionSafe",
                NSURLErrorDomain,
            ]
            #expect(
                acceptableDomains.contains(nsError.domain),
                "Unexpected error domain: \(nsError.domain) — \(nsError.localizedDescription)"
            )
        }
    }

    /// Delegate-style variant — `ThroughputService.SpeedProbe` uses this
    /// path. Same guarantee: throw, don't crash.
    @Test("safeDataTask(with:) on invalidated session throws instead of SIGABRT")
    func safeDataTaskOnInvalidatedSession() async throws {
        let session = URLSession(configuration: .ephemeral)
        session.invalidateAndCancel()
        try? await Task.sleep(nanoseconds: 50_000_000)

        let request = URLRequest(url: URL(string: "https://example.com")!)

        #expect(throws: (any Error).self) {
            _ = try session.safeDataTask(with: request)
        }
    }

    /// Cancellation forwarding: cancelling the parent `Task` must cancel
    /// the in-flight URLSession task (so `safeData` returns
    /// `URLError.cancelled` instead of leaking the request).
    @Test("safeData(for:) forwards Swift Task cancellation")
    func safeDataCancellationPropagates() async {
        // Use a URL that would otherwise take a long time so we have
        // a window to cancel inside. example.com is fine — we cancel
        // before the response would arrive.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "https://example.com")!)

        let task = Task {
            try await session.safeData(for: request)
        }
        // Cancel immediately. The continuation should resolve with
        // URLError.cancelled (URLSession's response to task.cancel()),
        // not hang or crash.
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Cancelled safeData call still produced a value.")
        } catch is CancellationError {
            // Acceptable — Swift Task cancellation may surface this
            // before URLSession's cancellation error.
        } catch let urlError as URLError where urlError.code == .cancelled {
            // Acceptable — most-common path.
        } catch {
            // Any other error path also proves "no crash", but flag it
            // for visibility.
            Issue.record("Unexpected error after cancel: \(error)")
        }
    }
}
