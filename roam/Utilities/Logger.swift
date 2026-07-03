import Foundation
import OSLog

enum Log {
    private static let logger = Logger(subsystem: "club.roam", category: "app")

    static func error(_ error: Error, category: String) {
        logger.error("[\(category, privacy: .public)] \(error.localizedDescription, privacy: .public)")
    }

    static func breadcrumb(_ message: String, category: String) {
        logger.info("[\(category, privacy: .public)] \(message, privacy: .public)")
    }
}

