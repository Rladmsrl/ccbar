import Foundation
import os

/// Subsystem-scoped loggers. Use these instead of `print`.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.rladmsrl.ClaudeStats"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let scanner = Logger(subsystem: subsystem, category: "scanner")
    static let parser = Logger(subsystem: subsystem, category: "parser")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let git = Logger(subsystem: subsystem, category: "git")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let notch = Logger(subsystem: subsystem, category: "notch")
    static let updater = Logger(subsystem: subsystem, category: "updater")
    static let usageLimit = Logger(subsystem: subsystem, category: "usage-limit")
    static let permission = Logger(subsystem: subsystem, category: "permission")
    static let session = Logger(subsystem: subsystem, category: "session")
}
