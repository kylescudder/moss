import Foundation
import OSLog

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.getmoss.moss"

    private static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static func error(_ error: Error, category: String) {
        logger(category).error("\(error.localizedDescription, privacy: .public)")
    }

    static func breadcrumb(_ message: String, category: String) {
        logger(category).info("\(message, privacy: .public)")
    }

    static func event(
        _ name: String,
        category: String,
        metadata: [String: CustomStringConvertible?] = [:]
    ) {
        let details = metadata
            .sorted { $0.key < $1.key }
            .map { key, value in "\(key)=\(value?.description ?? "nil")" }
            .joined(separator: " ")
        breadcrumb(details.isEmpty ? name : "\(name) \(details)", category: category)
    }

    /// Keeps auth codes and tokens out of diagnostic logs while preserving the
    /// callback shape needed to troubleshoot routing problems.
    static func redactedURLDescription(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "<invalid-url>"
        }

        if let queryItems = components.queryItems {
            components.queryItems = queryItems.map { item in
                guard sensitiveURLParameterNames.contains(item.name.lowercased()) else {
                    return item
                }
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
        }

        if let fragment = components.fragment {
            components.fragment = fragment
                .split(separator: "&")
                .map { pair -> String in
                    let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let name = parts.first,
                          sensitiveURLParameterNames.contains(name.lowercased()) else {
                        return String(pair)
                    }
                    return "\(name)=<redacted>"
                }
                .joined(separator: "&")
        }

        return components.string ?? "<redacted-url>"
    }

    private static let sensitiveURLParameterNames: Set<String> = [
        "access_token",
        "code",
        "id_token",
        "refresh_token",
        "token",
    ]
}
