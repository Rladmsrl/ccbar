import SwiftUI

/// Stacked daily token chart for the Dashboard's "Models" tab. One column per
/// day; each column is a stack of per-model segments, busiest model at the
/// base. Within a model's segment, the `cacheRead` portion is rendered with
/// the same colour as the solid portion plus a light diagonal stripe overlay
/// — matching the menu-bar popover's "By model" bars in ``UsageView``.
///
/// The chart is hand-rolled (instead of using `Charts.BarMark`) because
/// `BarMark` can't carry an arbitrary `Shape` overlay per segment.
/// `ModelTable` next to the chart doubles as the legend.
struct ModelsTrendChart: View {
    let series: TrendSeries
    let seriesID: String
    var includeCacheInTotals: Bool = false
    /// Resolves a canonical model id (e.g. `claude-opus-4-7`) to its display
    /// name. Passed in so the chart stays provider-agnostic.
    let displayName: (String) -> String
    @State private var cachedSnapshotKey: ModelsTrendChartSnapshot.Key?
    @State private var cachedSnapshot: ModelsTrendChartSnapshot?

    private static let chartHeight: CGFloat = 180
    private static let yAxisWidth: CGFloat = 44

    var body: some View {
        let key = ModelsTrendChartSnapshot.Key(seriesID: seriesID, includeCacheInTotals: includeCacheInTotals)
        let snapshot = cachedSnapshotKey == key
            ? (cachedSnapshot ?? makeSnapshot(key: key))
            : makeSnapshot(key: key)

        VStack(alignment: .leading, spacing: 0) {
            if snapshot.days.isEmpty {
                placeholder
            } else {
                chart(snapshot)
            }
        }
        .appSurface(.mainWindowCard, padding: 16)
        .onAppear { cacheSnapshotIfNeeded(key) }
        .onChange(of: key) { _, newKey in cacheSnapshotIfNeeded(newKey) }
    }

    // MARK: - Subviews

    private func chart(_ snapshot: ModelsTrendChartSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                yAxis(snapshot)
                plotArea(snapshot)
            }
            .frame(height: Self.chartHeight)
            xAxis(snapshot)
        }
    }

    private func yAxis(_ snapshot: ModelsTrendChartSnapshot) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(snapshot.yTicks.enumerated()), id: \.offset) { index, value in
                Text(Format.tokens(value))
                    .font(.sora(8).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                if index < snapshot.yTicks.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(width: Self.yAxisWidth)
    }

    private func plotArea(_ snapshot: ModelsTrendChartSnapshot) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                gridlines(in: geo.size)
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(snapshot.days) { day in
                        column(for: day, plotHeight: geo.size.height, yMax: snapshot.yMax)
                    }
                }
            }
        }
    }

    private func gridlines(in size: CGSize) -> some View {
        ZStack(alignment: .top) {
            ForEach(0...ModelsTrendChartSnapshot.yTickCount, id: \.self) { i in
                let y = size.height * CGFloat(i) / CGFloat(ModelsTrendChartSnapshot.yTickCount)
                Rectangle()
                    .fill(Color.stxStroke.opacity(0.5))
                    .frame(height: 0.5)
                    .offset(y: y - 0.25)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func column(for day: ModelsTrendChartSnapshot.DayColumn, plotHeight: CGFloat, yMax: Int) -> some View {
        // VStack of segments, smallest model first (top) so the busiest model
        // ends up at the base. Within each segment, the cache portion is
        // drawn above the solid portion (same colour, striped overlay).
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(day.segments.reversed()) { segment in
                let color = ModelPalette.color(at: segment.colorIndex)
                if segment.cache > 0 {
                    stripedRect(color: color)
                        .frame(height: barHeight(segment.cache, plotHeight: plotHeight, yMax: yMax))
                }
                if segment.solid > 0 {
                    Rectangle()
                        .fill(color)
                        .frame(height: barHeight(segment.solid, plotHeight: plotHeight, yMax: yMax))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stripedRect(color: Color) -> some View {
        ZStack {
            Rectangle().fill(color)
            DiagonalStripes(spacing: 4)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
        .clipped()
    }

    private func barHeight(_ tokens: Int, plotHeight: CGFloat, yMax: Int) -> CGFloat {
        guard yMax > 0 else { return 0 }
        return plotHeight * CGFloat(tokens) / CGFloat(yMax)
    }

    private func xAxis(_ snapshot: ModelsTrendChartSnapshot) -> some View {
        HStack(alignment: .top, spacing: 0) {
            // Spacer matching the Y-axis column width so labels align with bars.
            Color.clear.frame(width: Self.yAxisWidth + 8)
            HStack(alignment: .top, spacing: 1) {
                ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                    Text(snapshot.xLabelIndices.contains(index) ? Format.day(day.date) : "")
                        .font(.sora(8).monospacedDigit())
                        .foregroundStyle(Color.stxMuted)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var placeholder: some View {
        Text("No model activity in this range.")
            .font(.sora(11))
            .foregroundStyle(Color.stxMuted)
            .frame(maxWidth: .infinity, minHeight: Self.chartHeight, alignment: .center)
    }

    private func makeSnapshot(key: ModelsTrendChartSnapshot.Key) -> ModelsTrendChartSnapshot {
        ModelsTrendChartSnapshot(key: key, series: series)
    }

    private func cacheSnapshotIfNeeded(_ key: ModelsTrendChartSnapshot.Key) {
        guard cachedSnapshotKey != key else { return }
        cachedSnapshot = makeSnapshot(key: key)
        cachedSnapshotKey = key
    }
}

struct ModelsTrendChartSnapshot: Equatable {
    struct Key: Equatable {
        let seriesID: String
        let includeCacheInTotals: Bool
    }

    static let yTickCount = 4
    private static let targetXLabelCount = 8

    let key: Key
    let days: [DayColumn]
    let yMax: Int
    let yTicks: [Int]
    let xLabelIndices: Set<Int>

    init(key: Key, series: TrendSeries) {
        let days = Self.makeDays(series: series, includeCacheInTotals: key.includeCacheInTotals)
        let yMax = Self.niceCeiling(days.map(\.total).max() ?? 0)
        let step = max(1, yMax / Self.yTickCount)

        self.key = key
        self.days = days
        self.yMax = yMax
        self.yTicks = (0...Self.yTickCount).map { yMax - $0 * step }
        self.xLabelIndices = Self.makeXLabelIndices(dayCount: days.count)
    }

    /// Round `value` up to a "nice" number suitable as a chart's Y maximum
    /// (1, 2, 2.5, 5, or 10 × a power of ten). Returns at least 1.
    static func niceCeiling(_ value: Int) -> Int {
        guard value > 0 else { return 1 }
        let magnitude = pow(10.0, floor(log10(Double(value))))
        let normalized = Double(value) / magnitude
        let nice: Double
        switch normalized {
        case ...1: nice = 1
        case ...2: nice = 2
        case ...2.5: nice = 2.5
        case ...5: nice = 5
        default: nice = 10
        }
        return Int((nice * magnitude).rounded(.up))
    }

    private static func makeDays(series: TrendSeries, includeCacheInTotals: Bool) -> [DayColumn] {
        var byDay: [Date: [String: TokenUsage]] = [:]
        for bucket in series.buckets {
            let total = bucket.usage.total(includingCacheRead: includeCacheInTotals)
            guard total > 0 else { continue }
            byDay[bucket.start, default: [:]][bucket.model] = bucket.usage
        }

        let modelOrder = series.models
        let indexByModel = Dictionary(uniqueKeysWithValues: modelOrder.enumerated().map { ($0.element, $0.offset) })
        return byDay
            .map { date, usagesByModel in
                let segments: [DayColumn.Segment] = modelOrder.compactMap { model in
                    guard let usage = usagesByModel[model] else { return nil }
                    let total = usage.total(includingCacheRead: includeCacheInTotals)
                    guard total > 0 else { return nil }
                    let solid = total - (includeCacheInTotals ? usage.cacheReadTokens : 0)
                    let cache = includeCacheInTotals ? usage.cacheReadTokens : 0
                    return DayColumn.Segment(
                        model: model,
                        colorIndex: indexByModel[model] ?? 0,
                        solid: max(0, solid),
                        cache: max(0, cache)
                    )
                }
                return DayColumn(date: date, segments: segments)
            }
            .sorted { $0.date < $1.date }
    }

    private static func makeXLabelIndices(dayCount: Int) -> Set<Int> {
        guard dayCount > 0 else { return [] }
        if dayCount <= targetXLabelCount { return Set(0..<dayCount) }
        let step = Double(dayCount - 1) / Double(targetXLabelCount - 1)
        return Set((0..<targetXLabelCount).map { Int((Double($0) * step).rounded()) })
    }

    struct DayColumn: Identifiable, Equatable {
        let date: Date
        let segments: [Segment]
        var id: Date { date }
        var total: Int { segments.reduce(0) { $0 + $1.solid + $1.cache } }

        struct Segment: Identifiable, Equatable {
            let model: String
            let colorIndex: Int
            let solid: Int
            let cache: Int
            var id: String { model }
        }
    }
}

#if DEBUG
#Preview {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: .now)
    let models = ["claude-opus-4-7", "claude-haiku-4-5", "claude-sonnet-4-6"]
    let buckets: [ModelBucket] = (0..<14).flatMap { day -> [ModelBucket] in
        let start = calendar.date(byAdding: .day, value: -day, to: today)!
        return models.enumerated().map { idx, model in
            ModelBucket(
                model: model,
                start: start,
                usage: TokenUsage(
                    inputTokens: 100_000 * (idx + 1),
                    outputTokens: 800_000 / (idx + 1),
                    cacheReadTokens: 600_000 / (idx + 1),
                    cacheCreation5mTokens: 0,
                    cacheCreation1hTokens: 0
                )
            )
        }
    }
    let series = TrendSeries(granularity: .day, models: models, buckets: buckets)
    return ModelsTrendChart(
        series: series,
        seriesID: "preview",
        includeCacheInTotals: true,
        displayName: { ClaudeProvider.prettyName(for: $0) }
    )
    .padding(24)
    .frame(width: 760)
    .background(Color.stxBackground)
}
#endif
