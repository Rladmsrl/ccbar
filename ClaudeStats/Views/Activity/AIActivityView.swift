import SwiftUI
import Charts
import AppKit

/// The "Activity" pane: lines up macOS Screen Time coding-surface time against
/// AI activity, on a day timeline (Tyme-style) plus a multi-day trend of the
/// AI-assisted share. Reads `knowledgeC.db` — needs Full Disk Access.
struct AIActivityView: View {
    /// A resolved snapshot for the export render — the share window loads the
    /// data (via its own ``AIActivityViewModel``) and hands it in, since
    /// `ImageRenderer` is synchronous and can't wait on `.task`.
    struct ExportData {
        var range: ActivityRange
        var selectedDay: Date
        var dayActivity: DayActivity?
        var trend: [DayActivity]
        var permissionDenied: Bool
        var isLoading: Bool
    }

    /// `interactive` is the normal in-panel pane (scrolls, loads its own data);
    /// `export` renders a static, non-scrolling snapshot for `ImageRenderer`.
    enum Mode { case interactive, export(ExportData) }

    @Environment(AppEnvironment.self) private var env
    @State private var vm = AIActivityViewModel()
    var mode: Mode = .interactive

    private struct ReloadKey: Equatable {
        let token: UInt64
        let lastRefreshed: Date?
        let codingSurfaceBundleIDs: Set<String>
        let cliHostBundleIDs: Set<String>
        let provider: ProviderKind
    }

    var body: some View {
        if case .export(let data) = mode {
            exportBody(data)
        } else {
            interactiveBody
        }
    }

    private var interactiveBody: some View {
        @Bindable var vm = vm
        let codingSurfaceBundleIDs = env.preferences.effectiveCodingSurfaceBundleIDs
        let cliHostBundleIDs = env.preferences.effectiveCLIHostBundleIDs
        let provider = env.preferences.selectedProvider
        let key = ReloadKey(token: vm.reloadToken,
                            lastRefreshed: env.store.lastRefreshedAt,
                            codingSurfaceBundleIDs: codingSurfaceBundleIDs,
                            cliHostBundleIDs: cliHostBundleIDs,
                            provider: provider)

        return AppScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerRow

                if vm.permissionState == .needsFullDiskAccess {
                    permissionGate
                } else if vm.range.isTrend {
                    trendSection(vm.trend)
                } else {
                    daySection(vm.dayActivity)
                }
            }
            .padding(14)
        }
        .task(id: key) {
            await vm.reload(
                sessions: env.store.sessions(for: provider),
                codingSurfaceBundleIDs: codingSurfaceBundleIDs,
                cliHostBundleIDs: cliHostBundleIDs
            )
        }
        .onAppear { vm.refreshPermissionState() }
    }

    @ViewBuilder
    private func exportBody(_ d: ExportData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            staticHeader(range: d.range, selectedDay: d.selectedDay)

            if d.permissionDenied {
                exportPermissionNote
            } else if d.isLoading && d.dayActivity == nil && d.trend.isEmpty {
                Text("Loading activity…")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else if d.range.isTrend {
                trendSection(d.trend)
            } else {
                daySection(d.dayActivity)
            }
        }
        .padding(14)
    }

    private func staticHeader(range: ActivityRange, selectedDay: Date) -> some View {
        HStack(spacing: 10) {
            BracketBox(spacing: 6) {
                Text(range == .day ? Format.day(selectedDay).uppercased() : "LAST \(range.dayCount) DAYS")
                    .font(.sora(11, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.primary)
                    .monospacedDigit()
            }
            Spacer()
        }
    }

    private var exportPermissionNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SCREEN TIME ACCESS NOT GRANTED")
                .font(.sora(13, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.primary)
            Text("No coding-surface activity data to show — CCBar needs Full Disk Access to read macOS Screen Time.")
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .stxPanel(12)
    }

    // MARK: Header

    private var headerRow: some View {
        @Bindable var vm = vm
        return HStack(spacing: 10) {
            if vm.range == .day {
                HStack(spacing: 0) {
                    stepButton(systemName: "chevron.left") { vm.stepDay(-1) }
                    BracketBox(spacing: 6) {
                        Text(Format.day(vm.selectedDay).uppercased())
                            .font(.sora(11, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                    }
                    stepButton(systemName: "chevron.right", disabled: !vm.canStepForward) { vm.stepDay(1) }
                }
            } else {
                BracketBox(spacing: 6) {
                    Text("LAST \(vm.range.dayCount) DAYS")
                        .font(.sora(11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
            if vm.isLoading { ProgressView().controlSize(.mini) }
            HStack(spacing: 8) {
                ForEach(ActivityRange.allCases) { r in
                    RangeChip(label: r.shortLabel, isSelected: vm.range == r) { vm.range = r }
                }
            }
        }
    }

    private func stepButton(systemName: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.stxMuted.opacity(0.35) : Color.stxMuted)
        .disabled(disabled)
    }

    private struct RangeChip: View {
        let label: String
        let isSelected: Bool
        let action: () -> Void
        @State private var hovering = false
        var body: some View {
            Button(action: action) {
                VStack(spacing: 3) {
                    Text(label.uppercased())
                        .font(.sora(10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(isSelected ? .primary : (hovering ? Color.primary : Color.primary.opacity(0.40)))
                    Rectangle()
                        .fill(Color.stxAccent)
                        .frame(height: 1.5)
                        .scaleEffect(x: isSelected ? 1 : 0, anchor: .center)
                }
                .fixedSize()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.18), value: isSelected)
        }
    }

    // MARK: Permission gate

    private var permissionGate: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FULL DISK ACCESS REQUIRED")
                .font(.sora(13, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.primary)
            Text("CCBar reads macOS Screen Time (the Knowledge database) to see when your coding surfaces and CLI hosts were focused. macOS keeps that file behind Full Disk Access — grant it, then come back to this tab.")
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Open Full Disk Access settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("Re-check") { vm.bumpReload() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .font(.sora(10))
        }
        .stxPanel(12)
    }

    // MARK: Single-day section

    @ViewBuilder
    private func daySection(_ activity: DayActivity?) -> some View {
        summaryGrid(activity)
        timelinePanel(activity)
        compositionPanel(activity)
    }

    private func summaryGrid(_ a: DayActivity?) -> some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                statCell("Coding surface", Format.duration(a?.codingSurfaceSeconds ?? 0))
                statCell("AI active", Format.duration(a?.aiSeconds ?? 0))
            }
            GridRow {
                statCell("CLI host", Format.duration(a?.cliHostSeconds ?? 0))
                statCell("CLI + AI", Format.duration(a?.cliAIOverlapSeconds ?? 0))
            }
            GridRow {
                statCell("Overlap", Format.duration(a?.overlapSeconds ?? 0))
                statCell("AI-assisted", a.map { Format.percent($0.assistedRatio) } ?? "—")
            }
        }
    }

    private func statCell(_ title: String, _ value: String) -> some View {
        BracketBox(spacing: 7) {
            Text(title.uppercased() + ":")
                .font(.sora(9))
                .tracking(0.4)
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
                .layoutPriority(-1)
            Text(value)
                .font(.sora(13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .stxNumericValueTransition(value: value)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .layoutPriority(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 7)
    }

    // MARK: Day timeline

    private struct TimelineSegment: Identifiable {
        enum Kind { case codingSurface, cliHost, ai, overlap, cliAIOverlap }
        let id = UUID()
        let kind: Kind
        let interval: DateInterval
    }

    private func timelineSegments(_ a: DayActivity) -> [TimelineSegment] {
        a.codingSurfaceIntervals.map { TimelineSegment(kind: .codingSurface, interval: $0) }
        + a.cliHostIntervals.map { TimelineSegment(kind: .cliHost, interval: $0) }
        + a.aiIntervals.map { TimelineSegment(kind: .ai, interval: $0) }
        + a.overlapIntervals.map { TimelineSegment(kind: .overlap, interval: $0) }
        + a.cliAIOverlapIntervals.map { TimelineSegment(kind: .cliAIOverlap, interval: $0) }
    }

    /// `[floor(earliest, hour), ceil(latest, hour)]`, or `nil` if the day is empty.
    private func timelineDomain(_ a: DayActivity) -> ClosedRange<Date>? {
        let all = a.codingSurfaceIntervals + a.cliHostIntervals + a.aiIntervals
        guard let lo = all.map(\.start).min(), let hi = all.map(\.end).max() else { return nil }
        let cal = Calendar.current
        let start = cal.dateInterval(of: .hour, for: lo)?.start ?? lo
        let endHour = cal.dateInterval(of: .hour, for: hi)?.end ?? hi
        return start...max(endHour, start.addingTimeInterval(3600))
    }

    private func axisStrideHours(_ domain: ClosedRange<Date>) -> Int {
        let hours = domain.upperBound.timeIntervalSince(domain.lowerBound) / 3600
        if hours <= 8 { return 1 }
        if hours <= 16 { return 2 }
        return 3
    }

    private static let codingSurfaceBaseColor = Color.primary.opacity(0.26)
    private static let cliHostBaseColor = Color.blue.opacity(0.30)
    private static let aiBaseColor = Color.stxAccent.opacity(0.40)
    private static let overlapColor = Color.stxAccent
    private static let cliOverlapColor = Color.blue.opacity(0.72)

    @ViewBuilder
    private func timelinePanel(_ a: DayActivity?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("DAY TIMELINE")
                    .font(.sora(13, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(.primary)
                Spacer()
            }
            Text("CODING SURFACE · CLI HOST · AI ACTIVE")
                .font(.sora(9))
                .tracking(0.8)
                .foregroundStyle(Color.stxMuted)

            if let a, !a.isEmpty, let domain = timelineDomain(a) {
                timelineLegend
                StxRule()
                timelineChart(a, domain: domain)
            } else {
                Text("No coding-surface, CLI host, or AI activity recorded for this day.")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .stxPanel(12)
    }

    private var timelineLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                legendChip("SURFACE", Self.codingSurfaceBaseColor)
                legendChip("CLI HOST", Self.cliHostBaseColor)
                legendChip("AI ACTIVE", Self.aiBaseColor)
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                legendChip("SURFACE + AI", Self.overlapColor)
                legendChip("CLI + AI", Self.cliOverlapColor)
                Spacer(minLength: 0)
            }
        }
    }

    private func legendChip(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 8, height: 8)
            Text(label)
                .font(.sora(9))
                .tracking(0.4)
                .foregroundStyle(Color.stxMuted)
        }
    }

    private func timelineChart(_ a: DayActivity, domain: ClosedRange<Date>) -> some View {
        let stride = axisStrideHours(domain)
        return Chart(timelineSegments(a)) { seg in
            RectangleMark(
                xStart: .value("Start", seg.interval.start),
                xEnd: .value("End", seg.interval.end),
                yStart: .value("Lo", laneRange(seg.kind).lowerBound),
                yEnd: .value("Hi", laneRange(seg.kind).upperBound)
            )
            .foregroundStyle(color(for: seg.kind))
            .cornerRadius(1)
        }
        .chartYScale(domain: 0...1)
        .chartYAxis(.hidden)
        .chartXScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: stride)) { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.hour())
                            .font(.sora(8))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 96)
    }

    private func laneRange(_ kind: TimelineSegment.Kind) -> ClosedRange<Double> {
        switch kind {
        case .cliHost: return 0.06...0.28
        case .ai: return 0.36...0.58
        case .codingSurface: return 0.66...0.94
        case .overlap: return 0.36...0.94
        case .cliAIOverlap: return 0.06...0.58
        }
    }

    private func color(for kind: TimelineSegment.Kind) -> Color {
        switch kind {
        case .codingSurface: return Self.codingSurfaceBaseColor
        case .cliHost: return Self.cliHostBaseColor
        case .ai: return Self.aiBaseColor
        case .overlap: return Self.overlapColor
        case .cliAIOverlap: return Self.cliOverlapColor
        }
    }

    // MARK: Composition bar

    private func compositionPanel(_ a: DayActivity?) -> some View {
        let overlap = a?.overlapSeconds ?? 0
        let solo = a?.soloCodingSurfaceSeconds ?? 0
        let cliAI = a?.cliAIOverlapSeconds ?? 0
        let cliOnly = max(0, (a?.cliHostSeconds ?? 0) - cliAI)
        let aiOnly = a?.aiOnlySeconds ?? 0
        let total = max(1, overlap + solo + cliAI + cliOnly + aiOnly)
        let parts: [(String, Color, TimeInterval)] = [
            ("AI-assisted coding", Self.overlapColor, overlap),
            ("Solo coding surface", Self.codingSurfaceBaseColor, solo),
            ("CLI + AI", Self.cliOverlapColor, cliAI),
            ("CLI host only", Self.cliHostBaseColor, cliOnly),
            ("AI outside surface/CLI", Self.aiBaseColor, aiOnly),
        ]
        return VStack(alignment: .leading, spacing: 8) {
            Text("HOW THE TIME SPLIT")
                .font(.sora(11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color.stxMuted)
            if overlap + solo + cliAI + cliOnly + aiOnly <= 0 {
                Text("Nothing to break down for this day.")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted.opacity(0.7))
            } else {
                GeometryReader { geo in
                    HStack(spacing: 1) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            Rectangle()
                                .fill(part.1)
                                .frame(width: max(part.2 > 0 ? 2 : 0, geo.size.width * CGFloat(part.2 / total)))
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 6)
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    HStack(spacing: 6) {
                        Rectangle().fill(part.1).frame(width: 7, height: 7)
                        Text(part.0)
                            .font(.sora(10))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(Format.duration(part.2))
                            .font(.sora(10).monospacedDigit())
                            .stxNumericValueTransition(value: Format.duration(part.2))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
    }

    // MARK: Multi-day trend

    private struct TrendPoint: Identifiable {
        let day: Date
        let ratio: Double
        var id: TimeInterval { day.timeIntervalSinceReferenceDate }
    }

    @ViewBuilder
    private func trendSection(_ trend: [DayActivity]) -> some View {
        let points = trend.map { TrendPoint(day: $0.day.start, ratio: $0.assistedRatio) }
        let hasData = trend.contains { $0.codingSurfaceSeconds > 0 }
        let avgRatio = trendAverage(trend)

        Grid(horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                statCell("Coding surface", Format.duration(trend.reduce(0) { $0 + $1.codingSurfaceSeconds }))
                statCell("AI active", Format.duration(trend.reduce(0) { $0 + $1.aiSeconds }))
            }
            GridRow {
                statCell("CLI host", Format.duration(trend.reduce(0) { $0 + $1.cliHostSeconds }))
                statCell("CLI + AI", Format.duration(trend.reduce(0) { $0 + $1.cliAIOverlapSeconds }))
            }
            GridRow {
                statCell("Overlap", Format.duration(trend.reduce(0) { $0 + $1.overlapSeconds }))
                statCell("Avg AI-assisted", avgRatio.map { Format.percent($0) } ?? "—")
            }
        }

        VStack(alignment: .leading, spacing: 10) {
            Text("AI-ASSISTED SHARE · PER DAY")
                .font(.sora(13, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(.primary)
            Text("SURFACE + AI OVERLAP ÷ CODING SURFACE")
                .font(.sora(9))
                .tracking(0.8)
                .foregroundStyle(Color.stxMuted)
            if hasData {
                StxRule()
                trendChart(points)
            } else {
                Text("No coding-surface activity recorded in this range.")
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted.opacity(0.7))
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .stxPanel(12)
    }

    private func trendAverage(_ trend: [DayActivity]) -> Double? {
        let withSurface = trend.filter { $0.codingSurfaceSeconds > 0 }
        guard !withSurface.isEmpty else { return nil }
        let surface = withSurface.reduce(0) { $0 + $1.codingSurfaceSeconds }
        let overlap = withSurface.reduce(0) { $0 + $1.overlapSeconds }
        return surface > 0 ? overlap / surface : nil
    }

    private func trendChart(_ points: [TrendPoint]) -> some View {
        Chart(points) { p in
            AreaMark(x: .value("Day", p.day, unit: .day), y: .value("Share", p.ratio))
                .foregroundStyle(Color.stxAccent.opacity(0.16))
                .interpolationMethod(.catmullRom)
            LineMark(x: .value("Day", p.day, unit: .day), y: .value("Share", p.ratio))
                .foregroundStyle(Color.stxAccent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2))
        }
        .chartYScale(domain: 0...1)
        .chartYAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(Format.percent(v)).font(.sora(8)).foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Color.stxStroke)
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.month(.abbreviated).day())
                            .font(.sora(8))
                            .foregroundStyle(Color.stxMuted)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .frame(height: 150)
    }
}

#if DEBUG
#Preview("Activity") {
    AIActivityView()
        .environment(AppEnvironment.preview())
        .frame(width: 380, height: 480)
        .background(Color.stxBackground)
}
#endif
