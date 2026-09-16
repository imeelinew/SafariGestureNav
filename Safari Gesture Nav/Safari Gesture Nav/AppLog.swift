import Foundation
import os.log

enum AppLog {
    static let logger = Logger(subsystem: "dev.eli.safari.gesturenav", category: "engine")

    static func info(_ message: String) {
        logger.notice("\(message, privacy: .public)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }
}
