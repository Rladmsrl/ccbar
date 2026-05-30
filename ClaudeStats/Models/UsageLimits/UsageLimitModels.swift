import Foundation

enum UsageLimitStatus: String, Codable, Sendable, Hashable {
    case fresh
    case setupRequired
    case waitingForNextResponse
    case unavailable
    case unsupported
}

struct UsageLimitReport: Codable, Sendable, Hashable {
    let provider: ProviderKind
    let status: UsageLimitStatus
    let snapshot: UsageLimitSnapshot?
    let message: String?

    var lastCapturedAt: Date? { snapshot?.capturedAt }

    static func fresh(provider: ProviderKind, snapshot: UsageLimitSnapshot) -> UsageLimitReport {
        UsageLimitReport(provider: provider, status: .fresh, snapshot: snapshot, message: nil)
    }

    static func setupRequired(provider: ProviderKind, message: String) -> UsageLimitReport {
        UsageLimitReport(provider: provider, status: .setupRequired, snapshot: nil, message: message)
    }

    static func waitingForNextResponse(provider: ProviderKind, snapshot: UsageLimitSnapshot?, message: String) -> UsageLimitReport {
        UsageLimitReport(provider: provider, status: .waitingForNextResponse, snapshot: snapshot, message: message)
    }

    static func unavailable(provider: ProviderKind, message: String) -> UsageLimitReport {
        UsageLimitReport(provider: provider, status: .unavailable, snapshot: nil, message: message)
    }

    static func unsupported(provider: ProviderKind) -> UsageLimitReport {
        UsageLimitReport(provider: provider, status: .unsupported, snapshot: nil, message: nil)
    }
}

struct UsageLimitSnapshot: Codable, Sendable, Hashable {
    let provider: ProviderKind
    let windows: [UsageLimitWindow]
    let capturedAt: Date
    let sourceLabel: String
    let sourcePath: String?
    let planType: String?
    let limitID: String?

    var isEmpty: Bool { windows.isEmpty }

    /// Whether the snapshot file itself is recent enough to trust. Separate
    /// from per-window reset validity — a snapshot can be "fresh" (just
    /// written) while individual windows have already reset (the cache will
    /// catch up on the next Claude Code response).
    func isFresh(now: Date, ttl: TimeInterval) -> Bool {
        now.timeIntervalSince(capturedAt) <= ttl
    }

    /// True if at least one window has not yet hit its reset point — the
    /// cached `used_percentage` for that window is still authoritative.
    /// When every window has expired, the cache is genuinely stale and the
    /// next Claude Code response will replace it.
    func hasActiveWindow(now: Date) -> Bool {
        windows.contains { window in
            guard let resetAt = window.resetAt else { return true }
            return resetAt > now
        }
    }

    /// Window IDs whose reset already passed — UI surfaces "reset pending"
    /// for these without invalidating the whole snapshot.
    func staleWindowIDs(now: Date) -> Set<String> {
        Set(windows.compactMap { window -> String? in
            guard let resetAt = window.resetAt, resetAt <= now else { return nil }
            return window.id
        })
    }
}

struct UsageLimitWindow: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let usedPercent: Double
    let resetAt: Date?
    let windowMinutes: Int?

    var clampedUsedPercent: Double {
        min(100, max(0, usedPercent))
    }

    var remainingPercent: Double {
        100 - clampedUsedPercent
    }
}

extension ProviderKind {
    var supportsUsageLimits: Bool { true }
}

