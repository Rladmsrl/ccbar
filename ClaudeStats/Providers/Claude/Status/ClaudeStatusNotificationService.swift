import Foundation
import UserNotifications

enum ClaudeStatusNotificationAuthorizationStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var canSendNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: true
        case .notDetermined, .denied, .unknown: false
        }
    }
}

protocol ClaudeStatusNotificationServicing: Sendable {
    func authorizationStatus() async -> ClaudeStatusNotificationAuthorizationStatus
    func requestAuthorization() async -> ClaudeStatusNotificationAuthorizationStatus
    func sendStatusAlert(title: String, body: String, identifier: String) async throws
}

struct ClaudeStatusNotificationService: ClaudeStatusNotificationServicing {
    func authorizationStatus() async -> ClaudeStatusNotificationAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.map(settings.authorizationStatus))
            }
        }
    }

    func requestAuthorization() async -> ClaudeStatusNotificationAuthorizationStatus {
        let granted = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    Log.app.error("Claude Status notification authorization failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: granted)
            }
        }
        if !granted { return await authorizationStatus() }
        return await authorizationStatus()
    }

    func sendStatusAlert(title: String, body: String, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func map(_ status: UNAuthorizationStatus) -> ClaudeStatusNotificationAuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unknown
        }
    }
}
