import Foundation

/// Wraps an ordered list of `IPProvider`s and tries them sequentially
/// until one returns. Added v0.33.0 to keep the menu-bar widget
/// working when a user's VPN / proxy ruleset breaks the primary
/// provider's CDN but not the fallback's — the case that made the
/// previous single-provider build look "frozen" to users on Clash /
/// Surge / similar.
///
/// Design notes:
///
/// - **Sequential, not concurrent.** Racing both providers in parallel
///   would shave latency on the failure path but double the request
///   load and the per-user quota footprint on every healthy poll —
///   a bad trade when the primary returns in ~200 ms 99% of the time.
///   The 5-second poll loop in [[RefreshScheduler.swift]] is forgiving
///   of a one-time ~12 s worst case (primary URLSession timeout +
///   fallback fetch) on a network where the primary is genuinely
///   unreachable; the user only feels it once at network change, then
///   the next tick rides the fallback warmpath.
///
/// - **First error wins.** On all-fail we re-throw the *primary*
///   provider's error rather than the last fallback's. Rationale:
///   the user thinks of the primary as the canonical answer, the
///   primary's error message is what their muscle memory associates
///   with "the app couldn't reach the internet", and when all
///   providers fail at once the root cause is almost always upstream-
///   of-all (no network, system-wide proxy block). Showing the
///   primary's error keeps the diagnostic surface stable.
///
/// - **Cancellation-aware.** `fetch()` checks `Task.isCancelled` between
///   attempts so [[IPService.withHardTimeout]] can short-circuit the
///   whole chain at the wall-clock deadline. Without this, a slow
///   primary + slow fallback could each consume their full 10 s
///   URLSession timeout (20 s total) before the hard-timeout's
///   cancellation actually unwound the chain.
struct FallbackChainProvider: IPProvider {
    let name: String
    let providers: [any IPProvider]

    init(_ providers: [any IPProvider]) {
        precondition(!providers.isEmpty, "FallbackChainProvider requires at least one provider")
        self.providers = providers
        self.name = providers.map(\.name).joined(separator: " → ")
    }

    func fetch() async throws -> IPDataModel {
        var primaryError: Error?
        for (index, provider) in providers.enumerated() {
            try Task.checkCancellation()
            do {
                let model = try await provider.fetch()
                if index > 0 {
                    Log.network.info(
                        "IP lookup served by fallback provider \(provider.name, privacy: .public) (primary failed)"
                    )
                }
                return model
            } catch {
                if index == 0 { primaryError = error }
                Log.network.info(
                    "IP provider \(provider.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        // All providers failed. Prefer the primary's error; fall back to
        // a generic transport message only if the precondition above
        // somehow lied (providers empty after init — can't happen, but
        // the compiler doesn't know that).
        throw primaryError ?? IPServiceError.transport(message: "All IP providers failed")
    }
}
