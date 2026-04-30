import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var environment = AppEnvironment()
    private var statusBarController: StatusBarController?
    /// We don't use SwiftUI's `Settings { }` scene anymore — the
    /// `NSApp.sendAction(Selector("showSettingsWindow:"))` route is
    /// unreliable for LSUIElement apps with no main menu and no
    /// already-open Settings window. Instead, we keep our own
    /// retained `NSWindow` here, host the same `SettingsScene`
    /// SwiftUI view inside it, and surface it on demand from the
    /// status bar's right-click menu. Lazy init so the window only
    /// allocates the first time the user actually asks for Settings.
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(environment: environment)
        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }

    /// Surface the Settings window. Used by the status bar context
    /// menu and any future entry point that needs to open settings
    /// without going through `NSApp.sendAction(showSettingsWindow:)`.
    ///
    /// The implementation creates a plain `NSWindow` hosting the
    /// `SettingsScene` SwiftUI view. We do NOT use SwiftUI's `Settings`
    /// scene because:
    ///
    /// 1. The `showSettingsWindow:` selector is dispatched via the
    ///    responder chain. For LSUIElement apps with no visible main
    ///    menu and no Settings window already on screen, the chain
    ///    has no responder for that selector — the call silently
    ///    no-ops. `DispatchQueue.main.async` deferral doesn't help
    ///    (we tried; that's why this exists).
    ///
    /// 2. SwiftUI's `Settings` scene also intercepts `⌘,` and other
    ///    auto-bindings. With our custom window we can wire those
    ///    explicitly if we want, without relying on SwiftUI's
    ///    invisible plumbing.
    ///
    /// The window is retained so re-opening reuses the same instance
    /// (closing only orders it out, never deallocates).
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if settingsWindow == nil {
            let host = NSHostingController(
                rootView: SettingsScene()
                    .environment(environment.settings)
                    .environment(environment)
            )
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "Here Settings")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: 460, height: 380))
            // Stop the runtime from releasing the window when the
            // close button is hit. We want re-opens to reuse this
            // instance so SettingsStore observers stay live.
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
