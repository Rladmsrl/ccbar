import SwiftUI
import Charts

enum UsageTrendMotion {
    static let chartMorph: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.28)
    static let chartCrossfade: Animation = .timingCurve(0.22, 1.0, 0.36, 1.0, duration: 0.22)
    static let periodChip: Animation = .easeOut(duration: 0.18)
}

struct UsageTrendChartSnapshot {
    let points: [UsageTrendChartPoint]
    let legendEntries: [UsageTrendLegendEntry]
    let viewport: STXDateChartViewport
    let renderFamilyID: String
    let viewportID: String
    let transitionScopeID: String
    let stageID: String
    let dataID: Int
    let isHourly: Bool
    let style: TrendChartStyle
    let useLog: Bool
    let stackByType: Bool
    let isEmpty: Bool
    let modelColorIndexByID: [String: Int]
    var updateID: String { "\(transitionScopeID)|\(stageID)|\(viewportID)|\(dataID)" }

    init(
        series: TrendSeries,
        rangeID: String,
        transitionScopeID: String = "default",
        style: TrendChartStyle,
        useLog: Bool,
        stackByType: Bool,
        displayName: (String) -> String
    ) {
        let isHourly = series.granularity == .hour
        let points = Self.trendPoints(series, style: style, useLog: useLog, stackByType: stackByType)
        let legendEntries: [UsageTrendLegendEntry]
        var modelColorIndexByID: [String: Int] = [:]
        if stackByType {
            legendEntries = Self.tokenTypeKeys.map { UsageTrendLegendEntry(id: $0.label, label: $0.label, color: $0.color) }
        } else {
            legendEntries = series.models.enumerated().map { index, model in
                modelColorIndexByID[model] = index
                return UsageTrendLegendEntry(id: model, label: displayName(model), color: ModelPalette.color(at: index))
            }
        }

        let isEmpty = series.buckets.isEmpty || series.isEmpty || points.isEmpty
        let yUpperBound = Self.chartUpperBound(points, style: style, useLog: useLog, stackByType: stackByType)
        let viewport = Self.chartViewport(series: series, points: points, yUpperBound: yUpperBound)
        self.points = points
        self.legendEntries = legendEntries
        self.viewport = viewport
        self.isHourly = isHourly
        self.style = style
        self.useLog = useLog
        self.stackByType = stackByType
        self.isEmpty = isEmpty
        self.modelColorIndexByID = modelColorIndexByID
        self.transitionScopeID = transitionScopeID

        let renderFamilyID = [
            isHourly ? "hour" : "day",
            Self.renderFamily(style: style, stackByType: stackByType),
            useLog ? "log" : "linear",
        ].joined(separator: "|")
        self.renderFamilyID = renderFamilyID
        self.stageID = "\(isEmpty ? "empty" : "data")|\(renderFamilyID)"
        self.viewportID = Self.viewportID(rangeID: rangeID, viewport: viewport)
        self.dataID = Self.dataID(points: points, yUpperBound: yUpperBound)
    }

    private static func trendPoints(
        _ series: TrendSeries,
        style: TrendChartStyle,
        useLog: Bool,
        stackByType: Bool
    ) -> [UsageTrendChartPoint] {
        if stackByType {
            var byStart: [Date: TokenUsage] = [:]
            for bucket in series.buckets {
                byStart[bucket.start, default: .zero] += bucket.usage
            }
            let starts = byStart.keys.sorted()
            return tokenTypeKeys.flatMap { key in
                starts.compactMap { date -> UsageTrendChartPoint? in
                    let value = tokenTypeValue(byStart[date] ?? .zero, label: key.label)
                    if style == .bar && value == 0 { return nil }
                    return UsageTrendChartPoint(series: key.label, date: date, value: Double(value))
                }
            }
        }

        switch style {
        case .bar:
            return series.models.flatMap { model in
                series.buckets(for: model)
                    .filter { $0.tokens > 0 }
                    .map { UsageTrendChartPoint(series: model, date: $0.start, value: Double($0.tokens)) }
            }
        case .line:
            let count = series.buckets(for: series.models.first ?? "").count
            let window = Smoothing.adaptiveWindow(count: count, granularity: series.granularity)
            return series.models.flatMap { model in
                let buckets = series.buckets(for: model)
                var values = Smoothing.movingAverage(buckets.map { Double($0.tokens) }, window: window)
                if useLog { values = values.map { log1p($0) } }
                return zip(buckets, values).map { UsageTrendChartPoint(series: model, date: $0.start, value: $1) }
            }
        }
    }

    private static func chartUpperBound(
        _ points: [UsageTrendChartPoint],
        style: TrendChartStyle,
        useLog: Bool,
        stackByType: Bool
    ) -> Double {
        let visibleMax: Double
        if style == .bar || stackByType {
            let sums = Dictionary(grouping: points, by: \.date).mapValues { rows in
                rows.reduce(0) { $0 + $1.value }
            }
            visibleMax = sums.values.max() ?? 1
        } else {
            visibleMax = points.map(\.value).max() ?? 1
        }

        if useLog {
            return log1p(niceTokenCeiling(expm1(max(1, visibleMax))))
        }
        return niceTokenCeiling(max(1, visibleMax))
    }

    private static func chartViewport(
        series: TrendSeries,
        points: [UsageTrendChartPoint],
        yUpperBound: Double
    ) -> STXDateChartViewport {
        let starts = series.buckets.map(\.start).isEmpty
            ? points.map(\.date)
            : series.buckets.map(\.start)
        let xStart = starts.min() ?? Date(timeIntervalSinceReferenceDate: 0)
        let rawXEnd = starts.max() ?? xStart
        let unit: Calendar.Component = series.granularity == .hour ? .hour : .day
        let fallbackInterval: TimeInterval = series.granularity == .hour ? 3_600 : 86_400
        let xEnd = Calendar.current.date(byAdding: unit, value: 1, to: rawXEnd)
            ?? rawXEnd.addingTimeInterval(fallbackInterval)
        return STXDateChartViewport(xStart: xStart, xEnd: xEnd, yStart: 0, yEnd: yUpperBound)
    }

    private static func renderFamily(style: TrendChartStyle, stackByType: Bool) -> String {
        switch (style, stackByType) {
        case (.line, false):
            "model-line"
        case (.line, true):
            "type-area"
        case (.bar, false):
            "model-bar"
        case (.bar, true):
            "type-bar"
        }
    }

    private static func viewportID(rangeID: String, viewport: STXDateChartViewport) -> String {
        [
            rangeID,
            String(Int(viewport.xStart.timeIntervalSinceReferenceDate.rounded())),
            String(Int(viewport.xEnd.timeIntervalSinceReferenceDate.rounded())),
            String(Int((viewport.yStart * 1_000).rounded())),
            String(Int((viewport.yEnd * 1_000).rounded())),
        ].joined(separator: "|")
    }

    private static func niceTokenCeiling(_ value: Double) -> Double {
        guard value > 0 else { return 1 }
        let magnitude = pow(10.0, floor(log10(value)))
        let normalized = value / magnitude
        let nice: Double
        switch normalized {
        case ...1:
            nice = 1
        case ...2:
            nice = 2
        case ...2.5:
            nice = 2.5
        case ...5:
            nice = 5
        default:
            nice = 10
        }
        return max(1, nice * magnitude)
    }

    private static func dataID(points: [UsageTrendChartPoint], yUpperBound: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(points.count)
        hasher.combine(Int((yUpperBound * 1_000).rounded()))
        for point in points {
            hasher.combine(point.id)
            hasher.combine(Int((point.value * 1_000).rounded()))
        }
        return hasher.finalize()
    }

    static let tokenTypeKeys: [(label: String, color: Color)] = [
        ("Output", Color.stxRamp[0]),
        ("Input", Color.stxRamp[1]),
        ("Cache Write", Color.stxRamp[2]),
        ("Cache Read", Color.stxRamp[3]),
    ]

    private static func tokenTypeValue(_ usage: TokenUsage, label: String) -> Int {
        switch label {
        case "Output": usage.outputTokens
        case "Input": usage.inputTokens
        case "Cache Write": usage.cacheCreationTotalTokens
        case "Cache Read": usage.cacheReadTokens
        default: 0
        }
    }
}

struct UsageTrendChartPoint: Identifiable {
    let series: String
    let date: Date
    let value: Double

    var id: String { "\(series)|\(date.timeIntervalSinceReferenceDate)" }
}

struct UsageTrendLegendEntry: Identifiable {
    let id: String
    let label: String
    let color: Color
}

struct UsageTrendChartView<Legend: View>: View {
    let snapshot: UsageTrendChartSnapshot
    let chartHeight: CGFloat
    let emptyMessage: String
    var axisFontSize: CGFloat = 8
    var barCornerRadius: CGFloat = 1
    let legend: Legend

    @State private var displayedSnapshot: UsageTrendChartSnapshot?
    @State private var chartStageNonce = 0

    init(
        snapshot: UsageTrendChartSnapshot,
        chartHeight: CGFloat,
        emptyMessage: String,
        axisFontSize: CGFloat = 8,
        barCornerRadius: CGFloat = 1,
        @ViewBuilder legend: () -> Legend
    ) {
        self.snapshot = snapshot
        self.chartHeight = chartHeight
        self.emptyMessage = emptyMessage
        self.axisFontSize = axisFontSize
        self.barCornerRadius = barCornerRadius
        self.legend = legend()
    }

    var body: some View {
        let displayed = displayedSnapshot ?? snapshot
        VStack(alignment: .leading, spacing: 10) {
            if !displayed.isEmpty {
                legend
                StxRule()
            }
            chartStage(displayed)
        }
        .animation(UsageTrendMotion.chartCrossfade, value: stageAnimationID(displayed))
        .onAppear {
            installSnapshotWithoutAnimation(snapshot)
        }
        .onChange(of: snapshot.updateID) { _, _ in
            stageSnapshotChange()
        }
    }

    private func chartStage(_ displayed: UsageTrendChartSnapshot) -> some View {
        ZStack {
            if displayed.isEmpty {
                Text(emptyMessage)
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted.opacity(0.72))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .id("empty|\(displayed.stageID)|\(chartStageNonce)")
                    .transition(stageTransition)
            } else {
                chart(displayed)
                    .id("chart|\(displayed.renderFamilyID)|\(chartStageNonce)")
                    .transition(stageTransition)
            }
        }
        .frame(height: chartHeight)
    }

    @ViewBuilder
    private func chart(_ displayed: UsageTrendChartSnapshot) -> some View {
        let base = Chart(displayed.points) { point in
            switch displayed.style {
            case .line:
                if displayed.stackByType {
                    AreaMark(
                        x: .value("Time", point.date, unit: displayed.isHourly ? .hour : .day),
                        y: .value("Tokens", point.value)
                    )
                    .foregroundStyle(by: .value("Type", point.series))
                    .interpolationMethod(.catmullRom)
                } else {
                    LineMark(
                        x: .value("Time", point.date, unit: displayed.isHourly ? .hour : .day),
                        y: .value("Tokens", point.value)
                    )
                    .foregroundStyle(by: .value("Model", point.series))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }
            case .bar:
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Tokens", point.value)
                )
                .foregroundStyle(by: .value(displayed.stackByType ? "Type" : "Model", point.series))
                .cornerRadius(barCornerRadius)
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let raw = value.as(Double.self) {
                        Text(Format.tokens(Int(displayed.useLog ? expm1(raw) : raw)))
                            .font(.sora(axisFontSize))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartXAxis {
            if displayed.isHourly {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    AxisGridLine().foregroundStyle(Color.stxStroke)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour())
                                .font(.sora(axisFontSize))
                                .foregroundStyle(Color.stxMuted)
                        }
                    }
                }
            } else {
                AxisMarks { value in
                    AxisGridLine().foregroundStyle(Color.stxStroke)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.month(.abbreviated).day())
                                .font(.sora(axisFontSize))
                                .foregroundStyle(Color.stxMuted)
                        }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .animation(UsageTrendMotion.chartMorph, value: displayed.dataID)
        .stxDateChartViewportTransition(displayed.viewport, value: displayed.viewportID)

        if displayed.stackByType {
            base.chartForegroundStyleScale(
                domain: UsageTrendChartSnapshot.tokenTypeKeys.map(\.label),
                range: UsageTrendChartSnapshot.tokenTypeKeys.map(\.color)
            )
        } else {
            base.chartForegroundStyleScale(mapping: { (key: String) in
                ModelPalette.color(at: displayed.modelColorIndexByID[key] ?? 0)
            })
        }
    }

    private var stageTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.985, anchor: .center))
    }

    private func stageAnimationID(_ displayed: UsageTrendChartSnapshot) -> String {
        "\(displayed.stageID)|\(chartStageNonce)"
    }

    @MainActor
    private func stageSnapshotChange() {
        guard let previous = displayedSnapshot else {
            installSnapshotWithoutAnimation(snapshot)
            return
        }

        let isSameDataStage = previous.renderFamilyID == snapshot.renderFamilyID
            && !previous.isEmpty
            && !snapshot.isEmpty
        let isScopeChange = previous.transitionScopeID != snapshot.transitionScopeID
        let isShrinkingTimeAxis = snapshot.viewport.xDuration < previous.viewport.xDuration - 0.5

        if isScopeChange || (isSameDataStage && isShrinkingTimeAxis) {
            withAnimation(UsageTrendMotion.chartCrossfade) {
                chartStageNonce += 1
                displayedSnapshot = snapshot
            }
            return
        }

        displayedSnapshot = snapshot
    }

    @MainActor
    private func installSnapshotWithoutAnimation(_ snapshot: UsageTrendChartSnapshot) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            displayedSnapshot = snapshot
        }
    }
}
