import OSLog

enum Log {
    static let subsystem = "app.here-macos"

    static let app        = Logger(subsystem: subsystem, category: "app")
    static let network    = Logger(subsystem: subsystem, category: "network")
    static let statusBar  = Logger(subsystem: subsystem, category: "status-bar")
    static let scheduler  = Logger(subsystem: subsystem, category: "scheduler")
    static let cache      = Logger(subsystem: subsystem, category: "cache")
    static let settings   = Logger(subsystem: subsystem, category: "settings")
    static let geocode    = Logger(subsystem: subsystem, category: "geocode")
    static let sleepWake  = Logger(subsystem: subsystem, category: "sleep-wake")
    static let launch     = Logger(subsystem: subsystem, category: "launch-at-login")
}
