import SwiftUI
import Charts

struct ActivityTrendPanel: View {
    let days: [DayActivity]

    private var points: [ActivityTrendPoint] {
        days.map { ActivityTrendPoint(day: $0.day.start, ratio: $0.assistedRatio) }
    }

    private var hasCodingSurfaceData: Bool {
        days.contains { $0.codingSurfaceSeconds > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("AI-ASSISTED SHARE")
                    .font(.sora(13, weight: .semibold))
                    .tracking(1.0)
                Spacer()
                Text("Surface + AI / coding surface")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }

            Text("Daily share of GUI coding-surface focus that overlapped with AI activity.")
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)

            if hasCodingSurfaceData {
                StxRule()
                chart
            } else {
                Text("No coding-surface activity recorded in this range.")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
            }
        }
        .mainWindowPanel(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI-assisted share trend")
    }

    private var chart: some View {
        Chart(points) { point in
            AreaMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Share", point.ratio)
            )
            .foregroundStyle(Color.stxAccent.opacity(0.16))
            .interpolationMethod(.catmullRom)

            LineMark(
                x: .value("Day", point.day, unit: .day),
                y: .value("Share", point.ratio)
            )
            .foregroundStyle(Color.stxAccent)
            .interpolationMethod(.catmullRom)
            .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(Format.percent(raw))
                            .font(.sora(8))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.month(.abbreviated).day())
                            .font(.sora(8))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 220)
        .accessibilityLabel("Daily AI-assisted share")
    }
}

struct ActivityDailyBreakdownPanel: View {
    let days: [DayActivity]

    private var maxCodingSurfaceSeconds: TimeInterval {
        max(1, days.map(\.codingSurfaceSeconds).max() ?? 1)
    }

    private var maxCLIHostSeconds: TimeInterval {
        max(1, days.map(\.cliHostSeconds).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("DAILY BREAKDOWN")
                    .font(.sora(13, weight: .semibold))
                    .tracking(1.0)
                Spacer()
                Text("\(activeDayCount) active days")
                    .font(.sora(10))
                    .stxNumericValueTransition(value: activeDayCount)
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }

            if days.isEmpty || activeDayCount == 0 {
                Text("No daily activity to list.")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
            } else {
                columnHeader
                LazyVStack(spacing: 0) {
                    ForEach(days, id: \.day.start) { day in
                        ActivityDailyBreakdownRow(
                            day: day,
                            maxCodingSurfaceSeconds: maxCodingSurfaceSeconds,
                            maxCLIHostSeconds: maxCLIHostSeconds
                        )
                        if day.day.start != days.last?.day.start {
                            StxRule()
                        }
                    }
                }
            }
        }
        .mainWindowPanel(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily breakdown")
    }

    private var activeDayCount: Int {
        days.filter { !$0.isEmpty }.count
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Day")
                .frame(width: 56, alignment: .leading)
            Text("Assist")
                .frame(width: 44, alignment: .trailing)
            Spacer(minLength: 8)
            Text("Surface")
                .frame(minWidth: 62, alignment: .trailing)
            Text("Overlap")
                .frame(minWidth: 62, alignment: .trailing)
            Text("CLI")
                .frame(minWidth: 62, alignment: .trailing)
            Text("CLI + AI")
                .frame(minWidth: 62, alignment: .trailing)
        }
        .font(.sora(9, weight: .medium))
        .foregroundStyle(Color.stxMuted)
        .textCase(.uppercase)
    }
}

private struct ActivityDailyBreakdownRow: View {
    let day: DayActivity
    let maxCodingSurfaceSeconds: TimeInterval
    let maxCLIHostSeconds: TimeInterval

    private var codingSurfaceWidthRatio: Double {
        day.codingSurfaceSeconds / max(1, maxCodingSurfaceSeconds)
    }

    private var cliHostWidthRatio: Double {
        day.cliHostSeconds / max(1, maxCLIHostSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(Format.day(day.day.start))
                    .font(.sora(12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 56, alignment: .leading)

                Text(Format.percent(day.assistedRatio))
                    .font(.sora(12, weight: .semibold).monospacedDigit())
                    .stxNumericValueTransition(value: Format.percent(day.assistedRatio))
                    .foregroundStyle(.primary)
                    .frame(width: 44, alignment: .trailing)

                Spacer(minLength: 8)

                Text(Format.duration(day.codingSurfaceSeconds))
                    .font(.sora(11).monospacedDigit())
                    .stxNumericValueTransition(value: Format.duration(day.codingSurfaceSeconds))
                    .foregroundStyle(Color.stxMuted)
                    .frame(minWidth: 62, alignment: .trailing)

                Text(Format.duration(day.overlapSeconds))
                    .font(.sora(11).monospacedDigit())
                    .stxNumericValueTransition(value: Format.duration(day.overlapSeconds))
                    .foregroundStyle(Color.stxMuted)
                    .frame(minWidth: 62, alignment: .trailing)

                Text(Format.duration(day.cliHostSeconds))
                    .font(.sora(11).monospacedDigit())
                    .stxNumericValueTransition(value: Format.duration(day.cliHostSeconds))
                    .foregroundStyle(Color.stxMuted)
                    .frame(minWidth: 62, alignment: .trailing)

                Text(Format.duration(day.cliAIOverlapSeconds))
                    .font(.sora(11).monospacedDigit())
                    .stxNumericValueTransition(value: Format.duration(day.cliAIOverlapSeconds))
                    .foregroundStyle(Color.stxMuted)
                    .frame(minWidth: 62, alignment: .trailing)
            }

            VStack(spacing: 3) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.08))

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.primary.opacity(0.18))
                            .frame(width: proxy.size.width * CGFloat(codingSurfaceWidthRatio))

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.stxAccent)
                            .frame(width: proxy.size.width * CGFloat(day.assistedRatio) * CGFloat(codingSurfaceWidthRatio))
                    }
                }
                .frame(height: 6)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.blue.opacity(0.08))

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.blue.opacity(0.24))
                            .frame(width: proxy.size.width * CGFloat(cliHostWidthRatio))

                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.blue.opacity(0.72))
                            .frame(width: proxy.size.width * CGFloat(day.cliHostSeconds > 0 ? day.cliAIOverlapSeconds / day.cliHostSeconds : 0) * CGFloat(cliHostWidthRatio))
                    }
                }
                .frame(height: 5)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.day(day.day.start)), \(Format.percent(day.assistedRatio)) AI-assisted, \(Format.duration(day.codingSurfaceSeconds)) coding-surface time, \(Format.duration(day.cliHostSeconds)) CLI host time")
    }
}

private struct ActivityTrendPoint: Identifiable {
    let day: Date
    let ratio: Double

    var id: TimeInterval {
        day.timeIntervalSinceReferenceDate
    }
}

#if DEBUG
#Preview {
    ActivityTrendPanel(days: [])
        .padding(24)
        .frame(width: 760)
        .background(Color.stxBackground)
}
#endif
