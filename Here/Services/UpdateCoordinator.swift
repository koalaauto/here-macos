import AppKit
import Foundation

/// Glue between `UpdateChecker`, `SettingsStore`, and the user-facing
/// alert. Single place that:
///   1. Schedules periodic checks honouring `SettingsStore.updateCheckFrequency`
///   2. Calls `UpdateChecker`, persists the last-checked timestamp
///   3. Presents the "Update available" / "Up to date" / error alert
///
/// `@MainActor` because steps 2-3 touch NSAlert + NSWorkspace + the
/// observable SettingsStore. Network I/O is fronted by the
/// `UpdateChecker` actor, which keeps the URLSession off the main
/// thread regardless.
///
/// We don't hand out the latest result for UI consumption: there's
/// only one place that reads it (the About panel's "Check now" button)
/// and it gets the result through the call's `await`.
@MainActor
final class UpdateCoordinator {
    private let checker: UpdateChecker
    private let settings: SettingsStore
    private var timerTask: Task<Void, Never>?
    /// Re-entrancy guard so a double-tap on "Check now" or a periodic
    /// tick landing on top of a manual click doesn't fire two
    /// parallel HTTP calls and two stacked alerts.
    private var inFlight = false

    init(checker: UpdateChecker, settings: SettingsStore) {
        self.checker = checker
        self.settings = settings
    }

    /// Begin background polling. Called from `AppEnvironment.start()`.
    ///
    /// First probe is delayed 30 s so the cold-start IP fetch /
    /// latency probe / popover boot don't compete with us — the
    /// update check is best-effort background work, it can wait.
    func start() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            await self?.tick()
            // Wake up daily (smallest non-`.never` cadence) regardless
            // of the user's setting. The tick itself respects
            // `lastUpdateCheckAt` so weekly users only do a real fetch
            // once a week — the daily wake just means changes to the
            // frequency picker take effect within ~24 h instead of
            // requiring an app restart.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(24 * 60 * 60))
                if Task.isCancelled { break }
                await self?.tick()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    /// Manual "Check now" — bypasses cadence and the skipped-version
    /// suppression. Always presents an alert (success / up-to-date /
    /// error) so the user gets feedback for the click.
    func checkNow() async {
        await runCheck(loud: true, respectSkippedVersion: false)
    }

    // MARK: - Private

    /// Cadence-respecting tick. No-op when:
    /// - frequency is `.never`,
    /// - or last successful/attempted check is younger than the
    ///   configured interval.
    private func tick() async {
        guard let interval = settings.updateCheckFrequency.interval else { return }
        if let last = settings.lastUpdateCheckAt,
           Date().timeIntervalSince(last) < interval {
            return
        }
        await runCheck(loud: false, respectSkippedVersion: true)
    }

    private func runCheck(loud: Bool, respectSkippedVersion: Bool) async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        Log.update.info("Update check starting (loud: \(loud, privacy: .public))")
        let result: Result<UpdateChecker.UpdateInfo?, UpdateCheckError>
        do {
            let info = try await checker.checkForUpdate()
            result = .success(info)
        } catch let error as UpdateCheckError {
            result = .failure(error)
        } catch {
            result = .failure(.from(error))
        }
        // Always update `lastUpdateCheckAt`, even on failure — otherwise
        // a flaky network at the cadence boundary would re-probe every
        // tick. The user can still trigger a fresh attempt via the
        // "Check now" button.
        settings.lastUpdateCheckAt = Date()

        switch result {
        case .success(let info?):
            if respectSkippedVersion, settings.skippedUpdateVersion == info.latestVersion {
                Log.update.info(
                    "Suppressing alert; user previously skipped \(info.latestVersion, privacy: .public)"
                )
                return
            }
            present(info: info)
        case .success(nil):
            if loud { presentUpToDate() }
        case .failure(let error):
            Log.update.error("Check failed: \(error.userDescription, privacy: .public)")
            if loud { presentError(error) }
        }
    }

    private func present(info: UpdateChecker.UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Here \(info.latestVersion) is available")
        alert.informativeText = Self.summarize(notes: info.releaseNotes)
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Skip this version"))
        alert.addButton(withTitle: String(localized: "Remind me later"))

        // Bring Here forward so the modal isn't trapped behind whatever
        // the user is currently looking at — we're an LSUIElement app
        // with no Dock icon to click on.
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(info.releaseURL)
        case .alertSecondButtonReturn:
            settings.skippedUpdateVersion = info.latestVersion
            Log.update.info("User skipped \(info.latestVersion, privacy: .public)")
        default:
            // "Remind me later" — fall through; cadence will re-prompt
            // at the next interval boundary.
            break
        }
    }

    private func presentUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You're up to date")
        alert.informativeText = String(
            localized: "Here \(AppVersion.current) is the latest version."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func presentError(_ error: UpdateCheckError) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn't check for updates")
        alert.informativeText = error.userDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Tame markdown release notes for an `NSAlert.informativeText`.
    /// The control doesn't render markdown — left untouched, raw `##`
    /// headers and bullet syntax leak into the dialog. We strip the
    /// noisy bits and cap at a screenful of text so the alert stays
    /// dismissible.
    static func summarize(notes: String, maxLines: Int = 12, maxChars: Int = 800) -> String {
        if notes.isEmpty {
            return String(
                localized: "Open the release page to see what's new and download the new build."
            )
        }
        let trimmed = notes
            .components(separatedBy: .newlines)
            .map { line -> String in
                var l = line
                // Strip leading '#' (markdown headers) and the spaces
                // that typically follow.
                while l.first == "#" || l.first == " " || l.first == "*" || l.first == "-" {
                    l.removeFirst()
                }
                return l.trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        let head = trimmed.prefix(maxLines).joined(separator: "\n")
        if head.count <= maxChars { return head }
        let idx = head.index(head.startIndex, offsetBy: maxChars)
        return String(head[..<idx]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}
