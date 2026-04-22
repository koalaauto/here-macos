import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) lazy var environment = AppEnvironment()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(environment: environment)
        environment.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        environment.shutdown()
    }
}
