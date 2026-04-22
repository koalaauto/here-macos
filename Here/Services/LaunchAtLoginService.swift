import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginService {
    enum Availability: Sendable, Equatable {
        case available
        case requiresApplicationsFolder
    }

    var availability: Availability {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
            ? .available
            : .requiresApplicationsFolder
    }

    var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
            Log.launch.info("Registered for launch at login")
        } else {
            try SMAppService.mainApp.unregister()
            Log.launch.info("Unregistered from launch at login")
        }
    }
}
