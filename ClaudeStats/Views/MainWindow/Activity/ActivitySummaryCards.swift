import SwiftUI

struct ActivitySummaryMetrics: Equatable {
    var codingSurfaceSeconds: TimeInterval
    var aiSeconds: TimeInterval
    var overlapSeconds: TimeInterval
    var cliHostSeconds: TimeInterval
    var cliAIOverlapSeconds: TimeInterval
    var assistedRatio: Double?

    static func day(_ activity: DayActivity?) -> ActivitySummaryMetrics {
        ActivitySummaryMetrics(
            codingSurfaceSeconds: activity?.codingSurfaceSeconds ?? 0,
            aiSeconds: activity?.aiSeconds ?? 0,
            overlapSeconds: activity?.overlapSeconds ?? 0,
            cliHostSeconds: activity?.cliHostSeconds ?? 0,
            cliAIOverlapSeconds: activity?.cliAIOverlapSeconds ?? 0,
            assistedRatio: activity.map(\.assistedRatio)
        )
    }

    static func trend(_ days: [DayActivity]) -> ActivitySummaryMetrics {
        let codingSurface = days.reduce(0) { $0 + $1.codingSurfaceSeconds }
        let ai = days.reduce(0) { $0 + $1.aiSeconds }
        let overlap = days.reduce(0) { $0 + $1.overlapSeconds }
        let cliHost = days.reduce(0) { $0 + $1.cliHostSeconds }
        let cliAIOverlap = days.reduce(0) { $0 + $1.cliAIOverlapSeconds }
        let ratio = codingSurface > 0 ? overlap / codingSurface : nil

        return ActivitySummaryMetrics(
            codingSurfaceSeconds: codingSurface,
            aiSeconds: ai,
            overlapSeconds: overlap,
            cliHostSeconds: cliHost,
            cliAIOverlapSeconds: cliAIOverlap,
            assistedRatio: ratio
        )
    }
}

struct ActivitySummaryCards: View {
    let metrics: ActivitySummaryMetrics
    let assistedLabel: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    card("Coding surface", Format.duration(metrics.codingSurfaceSeconds))
                    card("AI active", Format.duration(metrics.aiSeconds))
                    card("CLI host", Format.duration(metrics.cliHostSeconds))
                }
                GridRow {
                    card("Overlap", Format.duration(metrics.overlapSeconds))
                    card("CLI + AI", Format.duration(metrics.cliAIOverlapSeconds))
                    card(assistedLabel, metrics.assistedRatio.map(Format.percent) ?? "--")
                }
            }

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    card("Coding surface", Format.duration(metrics.codingSurfaceSeconds))
                    card("AI active", Format.duration(metrics.aiSeconds))
                }
                GridRow {
                    card("CLI host", Format.duration(metrics.cliHostSeconds))
                    card("Overlap", Format.duration(metrics.overlapSeconds))
                }
                GridRow {
                    card("CLI + AI", Format.duration(metrics.cliAIOverlapSeconds))
                    card(assistedLabel, metrics.assistedRatio.map(Format.percent) ?? "--")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity summary")
    }

    private func card(_ label: String, _ value: String) -> some View {
        StatCard(label: label, value: value)
    }
}

#if DEBUG
#Preview {
    ActivitySummaryCards(
        metrics: ActivitySummaryMetrics(
            codingSurfaceSeconds: 4_200,
            aiSeconds: 2_700,
            overlapSeconds: 1_860,
            cliHostSeconds: 1_200,
            cliAIOverlapSeconds: 540,
            assistedRatio: 0.44
        ),
        assistedLabel: "AI-assisted"
    )
    .padding(24)
    .frame(width: 780)
    .background(Color.stxBackground)
}
#endif
