import SwiftUI

/// Shared sizing constants for the heatmap variants. ``ResponsiveHeatmap``
/// reads container width and computes the actual `cellSize` directly, clamping
/// to `[cellSizeMin, cellSizeMax]`.
enum HeatmapMetrics {
    static let spacing: CGFloat = 2
    static let weekdayColumnWidth: CGFloat = 16
    static let weekdayGap: CGFloat = 6
    static let cellSizeMax: CGFloat = 11
    static let cellSizeMin: CGFloat = 6

    /// Number of week-columns spanned by `range`. Cheap — uses a few
    /// `Calendar` calls instead of materializing the full ``CalendarGrid``.
    static func weekCount(for range: DateInterval, calendar: Calendar = .current) -> Int {
        let firstWeekStart = calendar.dateInterval(of: .weekOfYear, for: range.start)?.start ?? range.start
        let lastWeekStart = calendar.dateInterval(of: .weekOfYear, for: range.end)?.start ?? range.end
        let weeks = calendar.dateComponents([.weekOfYear], from: firstWeekStart, to: lastWeekStart).weekOfYear ?? 0
        return max(1, weeks + 1)
    }

    static func cellSize(forWidth width: CGFloat, weekCount: Int) -> CGFloat {
        guard weekCount > 0 else { return cellSizeMax }
        let labelWidth = weekdayColumnWidth + weekdayGap
        let available = max(0, width - labelWidth)
        let perCell = (available - CGFloat(weekCount - 1) * spacing) / CGFloat(weekCount)
        return min(cellSizeMax, max(cellSizeMin, floor(perCell)))
    }
}

/// Visual treatment for one heatmap day. Keeping this as plain data lets the
/// grid render every cell in one Canvas instead of allocating one SwiftUI view
/// per day during window resizes.
struct HeatmapCellStyle {
    let fill: Color
    var border: Color? = nil
    var borderStyle = StrokeStyle(lineWidth: 1)
}

/// Renders a single heatmap variant whose cell size is computed from the
/// container's width. Replaces the old `ViewThatFits`-based design that paid
/// to lay out every candidate cell size on every layout pass.
///
/// `cellSize` is the @State (not the raw width). The geometry observer maps
/// width → cellSize in its transform and only writes back when the result
/// actually changes — so body re-runs only ~6 times across a full resize
/// sweep (one per integer cellSize crossing) instead of per pixel.
struct ResponsiveHeatmap<Content: View>: View {
    let weekCount: Int
    @ViewBuilder var content: (CGFloat) -> Content
    @State private var cellSize: CGFloat = HeatmapMetrics.cellSizeMax

    var body: some View {
        let weeks = weekCount
        return content(cellSize)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { proxy in
                HeatmapMetrics.cellSize(forWidth: proxy.size.width, weekCount: weeks)
            } action: { newCellSize in
                if newCellSize > 0, newCellSize != cellSize {
                    cellSize = newCellSize
                }
            }
    }
}

/// GitHub-style yearly heatmap: a 7-row grid of week columns, with cell colour
/// driven by a quartile bucketing over the visible window's non-zero values.
///
/// The ramp uses the app's warm `.stxAccent` at four opacity stops so it sits
/// inside the instrument-panel chrome instead of borrowing GitHub's green.
struct HeatmapView: View {
    let cells: [HeatmapCell]
    let range: DateInterval
    /// Builds the hover label, e.g. `"5 commits"` or `"12.4k tokens"`. Receives
    /// raw `value`; the view appends the date.
    let valueLabel: (Int) -> String

    /// Cached so we don't rebuild a 365-entry dictionary on every body call.
    /// Recomputed via ``recompute()`` only when ``cells`` actually changes.
    @State private var valuesByDay: [Date: Int] = [:]
    @State private var quartiles: [Int] = []
    /// Pre-formatted tooltips per day. Same rationale as in `CompactHeatmap`:
    /// keep `DateFormatter.string` out of the per-cell body path.
    @State private var helpByDay: [Date: String] = [:]

    var body: some View {
        ResponsiveHeatmap(weekCount: HeatmapMetrics.weekCount(for: range)) { cellSize in
            VStack(alignment: .leading, spacing: 6) {
                CalendarGridCanvas(range: range, cellSize: cellSize, help: { helpByDay[$0] ?? "" }) { date, _ in
                    HeatmapCellStyle(fill: color(for: valuesByDay[date] ?? 0))
                }
                legend(cellSize: cellSize)
            }
        }
        .onAppear { recompute() }
        .onChange(of: cells) { _, _ in recompute() }
        .onChange(of: range) { _, _ in recompute() }
    }

    private func recompute() {
        let valuesByDay = Dictionary(uniqueKeysWithValues: cells.map { ($0.date, $0.value) })
        self.valuesByDay = valuesByDay
        let nonZero = cells.compactMap { $0.value > 0 ? $0.value : nil }.sorted()
        if nonZero.isEmpty {
            quartiles = []
        } else {
            func q(_ p: Double) -> Int {
                let idx = min(max(Int(Double(nonZero.count - 1) * p), 0), nonZero.count - 1)
                return nonZero[idx]
            }
            quartiles = [q(0.25), q(0.50), q(0.75)]
        }

        let grid = CalendarGrid(spanning: range)
        var help: [Date: String] = [:]
        help.reserveCapacity(grid.weeks.count * 7)
        let fmt = Self.dateFormatter
        for week in grid.weeks {
            for day in week where range.contains(day) {
                let value = valuesByDay[day] ?? 0
                help[day] = "\(valueLabel(value)) · \(fmt.string(from: day))"
            }
        }
        helpByDay = help
    }

    private func legend(cellSize: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text("Less").font(.sora(9)).foregroundStyle(Color.stxMuted)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(rampColor(step: step))
                    .frame(width: cellSize, height: cellSize)
            }
            Text("More").font(.sora(9)).foregroundStyle(Color.stxMuted)
        }
        .padding(.leading, HeatmapMetrics.weekdayColumnWidth + HeatmapMetrics.weekdayGap)
    }

    // MARK: - Colour ramp

    private func color(for value: Int) -> Color {
        guard value > 0 else { return rampColor(step: 0) }
        let q = quartiles
        if q.isEmpty { return rampColor(step: 1) }
        if value <= q[0] { return rampColor(step: 1) }
        if value <= q[1] { return rampColor(step: 2) }
        if value <= q[2] { return rampColor(step: 3) }
        return rampColor(step: 4)
    }

    /// 0 = empty cell colour; 1…4 = increasingly saturated accent. We layer
    /// accent over panel so the empty stop is a tinted muted background that
    /// reads as "this day is in range, no activity" — not "no data".
    private func rampColor(step: Int) -> Color {
        switch step {
        case 0: return Color.primary.opacity(0.08)
        case 1: return Color.stxAccent.opacity(0.22)
        case 2: return Color.stxAccent.opacity(0.45)
        case 3: return Color.stxAccent.opacity(0.72)
        default: return Color.stxAccent
        }
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Shared skeleton for the week-column grid: month-label strip, weekday
/// labels, and a 7-row × N-week Canvas grid. Earlier versions rendered one
/// SwiftUI shape per day; with three dashboard heatmaps that made resize
/// compression expensive because layout had to visit hundreds of cell views.
/// Canvas keeps the view tree flat while preserving the same responsive sizing.
struct CalendarGridCanvas: View {
    let range: DateInterval
    let cellSize: CGFloat
    var help: (Date) -> String = { _ in "" }
    var style: (Date, Bool) -> HeatmapCellStyle

    /// Cached so we don't rebuild ~370 `Date` objects on every layout pass.
    /// Refreshed only when `range` actually changes (e.g. user toggles 12M/YTD).
    @State private var grid: CalendarGrid
    @State private var hoveredHelp = ""

    init(range: DateInterval, cellSize: CGFloat,
         help: @escaping (Date) -> String = { _ in "" },
         style: @escaping (Date, Bool) -> HeatmapCellStyle) {
        self.range = range
        self.cellSize = cellSize
        self.help = help
        self.style = style
        self._grid = State(initialValue: CalendarGrid(spanning: range))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            monthLabels
            HStack(alignment: .top, spacing: HeatmapMetrics.weekdayGap) {
                weekdayLabels
                canvasGrid
            }
        }
        .onChange(of: range) { _, new in
            grid = CalendarGrid(spanning: new)
            hoveredHelp = ""
        }
    }

    private var monthLabels: some View {
        let columnStride = cellSize + HeatmapMetrics.spacing
        return ZStack(alignment: .topLeading) {
            ForEach(grid.monthLabels, id: \.weekIndex) { pos in
                Text(pos.label)
                    .font(.sora(9))
                    .foregroundStyle(Color.stxMuted)
                    .offset(x: CGFloat(pos.weekIndex) * columnStride)
            }
        }
        .frame(width: gridWidth, height: 11, alignment: .leading)
        .padding(.leading, HeatmapMetrics.weekdayColumnWidth + HeatmapMetrics.weekdayGap)
    }

    private var weekdayLabels: some View {
        VStack(spacing: HeatmapMetrics.spacing) {
            ForEach(0..<7, id: \.self) { row in
                let visible = !row.isMultiple(of: 2) // rows 1, 3, 5
                Text(visible ? grid.weekdaySymbols[row] : " ")
                    .font(.sora(9))
                    .foregroundStyle(Color.stxMuted)
                    .frame(width: HeatmapMetrics.weekdayColumnWidth, height: cellSize, alignment: .trailing)
            }
        }
    }

    private var canvasGrid: some View {
        Canvas { context, _ in
            let stride = cellSize + HeatmapMetrics.spacing
            let cornerRadius = min(2, cellSize / 3)

            for (weekIdx, week) in grid.weeks.enumerated() {
                for (dayIdx, date) in week.enumerated() where range.contains(date) {
                    let origin = CGPoint(
                        x: CGFloat(weekIdx) * stride,
                        y: CGFloat(dayIdx) * stride
                    )
                    let rect = CGRect(origin: origin, size: CGSize(width: cellSize, height: cellSize))
                    let path = Path(roundedRect: rect, cornerRadius: cornerRadius)
                    let cellStyle = style(date, true)

                    context.fill(path, with: .color(cellStyle.fill))
                    if let border = cellStyle.border {
                        let borderRect = rect.insetBy(dx: 0.5, dy: 0.5)
                        let borderPath = Path(roundedRect: borderRect, cornerRadius: cornerRadius)
                        context.stroke(borderPath, with: .color(border), style: cellStyle.borderStyle)
                    }
                }
            }
        }
        .frame(width: gridWidth, height: gridHeight)
        .contentShape(Rectangle())
        .help(hoveredHelp)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                updateHover(at: location)
            case .ended:
                if !hoveredHelp.isEmpty { hoveredHelp = "" }
            }
        }
    }

    private var gridWidth: CGFloat {
        guard !grid.weeks.isEmpty else { return 0 }
        return CGFloat(grid.weeks.count) * cellSize + CGFloat(grid.weeks.count - 1) * HeatmapMetrics.spacing
    }

    private var gridHeight: CGFloat {
        7 * cellSize + 6 * HeatmapMetrics.spacing
    }

    private func updateHover(at location: CGPoint) {
        guard cellSize > 0, !grid.weeks.isEmpty else { return setHoveredHelp("") }

        let stride = cellSize + HeatmapMetrics.spacing
        let weekIdx = Int(location.x / stride)
        let dayIdx = Int(location.y / stride)
        guard weekIdx >= 0, weekIdx < grid.weeks.count, dayIdx >= 0, dayIdx < 7 else {
            return setHoveredHelp("")
        }

        let cellX = location.x - CGFloat(weekIdx) * stride
        let cellY = location.y - CGFloat(dayIdx) * stride
        guard cellX <= cellSize, cellY <= cellSize else { return setHoveredHelp("") }

        let date = grid.weeks[weekIdx][dayIdx]
        setHoveredHelp(range.contains(date) ? help(date) : "")
    }

    private func setHoveredHelp(_ value: String) {
        if hoveredHelp != value { hoveredHelp = value }
    }
}

#if DEBUG
#Preview("Heatmap — populated") {
    let cal = Calendar.current
    let now = Date.now
    let range = DateInterval(
        start: cal.date(byAdding: .day, value: -364, to: cal.startOfDay(for: now))!,
        end: cal.dateInterval(of: .day, for: now)!.end
    )
    var cells: [HeatmapCell] = []
    var rng = SystemRandomNumberGenerator()
    for offset in 0..<365 {
        let day = cal.date(byAdding: .day, value: -offset, to: cal.startOfDay(for: now))!
        let r = Int.random(in: 0...10, using: &rng)
        let value = r < 4 ? 0 : (r < 7 ? 1 : (r < 9 ? 3 : 8))
        if value > 0 { cells.append(HeatmapCell(date: day, value: value)) }
    }
    return HeatmapView(cells: cells, range: range, valueLabel: { "\($0) commits" })
        .padding()
        .frame(width: 760)
}

#Preview("Heatmap — empty") {
    let cal = Calendar.current
    let range = DateInterval(
        start: cal.date(byAdding: .day, value: -90, to: cal.startOfDay(for: .now))!,
        end: cal.dateInterval(of: .day, for: .now)!.end
    )
    return HeatmapView(cells: [], range: range, valueLabel: { "\($0) commits" })
        .padding()
        .frame(width: 760)
}
#endif
