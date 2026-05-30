import SwiftUI
import Charts

struct ActivityTimelinePanel: View {
    let activity: DayActivity?

    private static let codingSurfaceColor = Color.primary.opacity(0.26)
    private static let cliHostColor = Color.blue.opacity(0.30)
    private static let aiColor = Color.stxAccent.opacity(0.40)
    private static let overlapColor = Color.stxAccent
    private static let cliOverlapColor = Color.blue.opacity(0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("DAY TIMELINE")
                    .font(.sora(13, weight: .semibold))
                    .tracking(1.0)
                Spacer()
                Text("Clock hour")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
            }

            Text("Coding surface, CLI host, and AI active windows.")
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)

            if let activity, !activity.isEmpty, let domain = timelineDomain(activity) {
                legend
                StxRule()
                chart(activity, domain: domain)
            } else {
                Text("No coding-surface, CLI host, or AI activity recorded for this day.")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 180, alignment: .center)
            }
        }
        .mainWindowPanel(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Day timeline")
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendChip("Coding surface", Self.codingSurfaceColor)
            legendChip("CLI host", Self.cliHostColor)
            legendChip("AI active", Self.aiColor)
            legendChip("Surface + AI", Self.overlapColor)
            legendChip("CLI + AI", Self.cliOverlapColor)
            Spacer(minLength: 0)
        }
    }

    private func legendChip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)
            Text(label)
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
        }
    }

    private func chart(_ activity: DayActivity, domain: ClosedRange<Date>) -> some View {
        let stride = axisStrideHours(domain)
        return Chart(timelineSegments(activity)) { segment in
            RectangleMark(
                xStart: .value("Start", segment.interval.start),
                xEnd: .value("End", segment.interval.end),
                yStart: .value("Lane low", laneRange(segment.kind).lowerBound),
                yEnd: .value("Lane high", laneRange(segment.kind).upperBound)
            )
            .foregroundStyle(color(for: segment.kind))
            .cornerRadius(1)
        }
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: stride)) { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour())
                            .font(.sora(8))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 180)
        .accessibilityLabel("Coding surface, CLI host, and AI activity timeline")
    }

    private func timelineSegments(_ activity: DayActivity) -> [ActivityTimelineSegment] {
        activity.codingSurfaceIntervals.map { ActivityTimelineSegment(kind: .codingSurface, interval: $0) }
        + activity.cliHostIntervals.map { ActivityTimelineSegment(kind: .cliHost, interval: $0) }
        + activity.aiIntervals.map { ActivityTimelineSegment(kind: .ai, interval: $0) }
        + activity.overlapIntervals.map { ActivityTimelineSegment(kind: .overlap, interval: $0) }
        + activity.cliAIOverlapIntervals.map { ActivityTimelineSegment(kind: .cliAIOverlap, interval: $0) }
    }

    private func timelineDomain(_ activity: DayActivity) -> ClosedRange<Date>? {
        let intervals = activity.codingSurfaceIntervals + activity.cliHostIntervals + activity.aiIntervals
        guard let first = intervals.map(\.start).min(),
              let last = intervals.map(\.end).max() else {
            return nil
        }

        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let end = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        return start...max(end, start.addingTimeInterval(3_600))
    }

    private func axisStrideHours(_ domain: ClosedRange<Date>) -> Int {
        let hours = domain.upperBound.timeIntervalSince(domain.lowerBound) / 3_600
        if hours <= 8 { return 1 }
        if hours <= 16 { return 2 }
        return 3
    }

    private func laneRange(_ kind: ActivityTimelineSegment.Kind) -> ClosedRange<Double> {
        switch kind {
        case .cliHost: 0.06...0.28
        case .ai: 0.36...0.58
        case .codingSurface: 0.66...0.94
        case .overlap: 0.36...0.94
        case .cliAIOverlap: 0.06...0.58
        }
    }

    private func color(for kind: ActivityTimelineSegment.Kind) -> Color {
        switch kind {
        case .codingSurface: Self.codingSurfaceColor
        case .cliHost: Self.cliHostColor
        case .ai: Self.aiColor
        case .overlap: Self.overlapColor
        case .cliAIOverlap: Self.cliOverlapColor
        }
    }
}

private struct ActivityTimelineSegment: Identifiable {
    enum Kind: String {
        case codingSurface, cliHost, ai, overlap, cliAIOverlap
    }

    let kind: Kind
    let interval: DateInterval

    var id: String {
        "\(kind.rawValue)-\(interval.start.timeIntervalSinceReferenceDate)-\(interval.end.timeIntervalSinceReferenceDate)"
    }
}

#if DEBUG
#Preview {
    ActivityTimelinePanel(activity: nil)
        .padding(24)
        .frame(width: 760)
        .background(Color.stxBackground)
}
#endif
