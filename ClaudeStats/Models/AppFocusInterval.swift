import Foundation

/// A run of time during which a given app held keyboard focus, read from
/// macOS Screen Time's `knowledgeC.db` app-usage streams.
struct AppFocusInterval: Sendable, Hashable {
    let bundleID: String
    let interval: DateInterval
}
