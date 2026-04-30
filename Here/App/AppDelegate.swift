import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var environment = AppEnvironment()
    private var statusBarController: StatusBarController?
    /// Retains the hidden NSPanel that captures `\.openSettings` —
    /// see `bootstrapOpenSettingsAction()`.
    private var openSettingsBootstrapWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(environment: environment)
        environment.start()
        bootstrapOpenSettingsAction()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }

    /// Stand up an invisible 1×1 NSPanel hosting a SwiftUI view that
    /// captures `\.openSettings` and stashes it on `AppEnvironment`,
    /// so AppKit code (the status bar's right-click menu) can open
    /// the SwiftUI `Settings { … }` scene without going through the
    /// flaky `NSApp.sendAction(showSettingsWindow:)` path.
    ///
    /// The panel must be `.orderFrontRegardless`-ed for SwiftUI to
    /// fire `onAppear` on the hosted view; alpha 0 + non-activating +
    /// ignores-mouse keeps it inert.
    private func bootstrapOpenSettingsAction() {
        let bootstrap = OpenSettingsBootstrap { [weak self] action in
            self?.environment.openSettingsAction = { action() }
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = NSHostingView(rootView: bootstrap)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.orderFrontRegardless()
        openSettingsBootstrapWindow = panel
    }
}

private struct OpenSettingsBootstrap: View {
    @Environment(\.openSettings) private var openSettings
    let register: (OpenSettingsAction) -> Void

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onAppear { register(openSettings) }
    }
}
