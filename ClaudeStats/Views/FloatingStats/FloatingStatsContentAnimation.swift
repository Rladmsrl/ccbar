import Foundation
import SwiftUI

enum FloatingStatsExpandedContentPhase: Equatable, Sendable {
    case hidden
    case waitingToReveal
    case revealing
    case visible
    case hiding

    var mountsExpandedContent: Bool {
        self != .hidden
    }

    var showsSectionContent: Bool {
        switch self {
        case .revealing, .visible, .hiding:
            true
        case .hidden, .waitingToReveal:
            false
        }
    }

    var expandedContentOpacity: Double {
        self == .hiding ? 0 : 1
    }
}

enum FloatingStatsContentSection: Int, CaseIterable, Equatable, Sendable {
    case header
    case rule
    case metrics
    case status
    case actions
}

enum FloatingStatsContentAnimation {
    static let panelExpandDuration: TimeInterval = 0.30
    static let panelCollapseDuration: TimeInterval = 0.20
    static let revealInitialDelay: TimeInterval = 0.06
    static let sectionFadeDuration: TimeInterval = 0.14
    static let sectionDelayStep: TimeInterval = 0.035
    static let collapseFadeDuration: TimeInterval = 0.10

    static func revealDelay(for section: FloatingStatsContentSection) -> TimeInterval {
        TimeInterval(section.rawValue) * sectionDelayStep
    }

    static func revealAnimation(for section: FloatingStatsContentSection) -> Animation {
        .easeOut(duration: sectionFadeDuration).delay(revealDelay(for: section))
    }

    static var totalRevealDuration: TimeInterval {
        guard let last = FloatingStatsContentSection.allCases.last else {
            return sectionFadeDuration
        }
        return revealDelay(for: last) + sectionFadeDuration
    }

    static func nanoseconds(for interval: TimeInterval) -> UInt64 {
        UInt64((interval * 1_000_000_000).rounded())
    }
}
