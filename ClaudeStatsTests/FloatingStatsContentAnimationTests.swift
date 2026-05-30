import Foundation
import Testing
@testable import ClaudeStats

@Suite("FloatingStatsContentAnimation")
struct FloatingStatsContentAnimationTests {
    @Test("Reveal sections are ordered from top-left to bottom-right")
    func revealSectionsUseExpectedOrder() {
        #expect(FloatingStatsContentSection.allCases == [.header, .rule, .metrics, .status, .actions])
    }

    @Test("Reveal delays increase by section")
    func revealDelaysIncreaseBySection() {
        let delays = FloatingStatsContentSection.allCases.map(FloatingStatsContentAnimation.revealDelay(for:))

        #expect(delays.first == 0)
        for index in delays.indices.dropFirst() {
            #expect(delays[index] > delays[delays.index(before: index)])
        }
    }

    @Test("Reveal initial delay is fixed")
    func revealInitialDelayIsFixed() {
        #expect(FloatingStatsContentAnimation.revealInitialDelay == 0.06)
    }

    @Test("Content fade completes before panel collapse")
    func contentFadeCompletesBeforePanelCollapse() {
        #expect(FloatingStatsContentAnimation.collapseFadeDuration == 0.10)
        #expect(FloatingStatsContentAnimation.collapseFadeDuration < FloatingStatsContentAnimation.panelCollapseDuration)
    }
}
