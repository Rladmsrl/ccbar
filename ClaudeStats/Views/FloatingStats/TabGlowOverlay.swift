import SwiftUI

/// Gradient-fill overlay for the floating stats tab. Encodes the
/// aggregate ``LiveSession/DisplayState`` of the user's visible sessions
/// as a coloured wash across the tab, so the overall fleet state is
/// readable in passing glance without expanding the tab.
///
/// **Inputs**
/// - `shape` — same `Shape` instance the parent uses for clip + background,
///   so the gradient fill and stroke match exactly.
/// - `segments` — per-segment render states. Each entry encodes one visible
///   session's `displayState` + `needsInput`; the overlay paints them as
///   N evenly-divided sub-rects with 0.5pt dividers between. Empty array
///   renders dormant. See `TabSegmenter.segments(from:cap:)` for the
///   `[LiveSession] → [TabSegment]` aggregation rules.
/// - `isExpanded` — true while the tab is hovered/expanded. The gradient
///   collapses to a quiet baseline so the expanded panel's contents are
///   the user's focus, not the tab edge.
/// - `edge` — which screen edge the tab is docked to. The gradient is
///   oriented so the saturated end faces the desktop and the faded end
///   faces the screen edge (catches your peripheral vision first).
///
/// **Visual encoding** (see ``TabFillSpec/spec(for:reduceMotion:)``)
/// State colours mirror the v2 mockup the user signed off on. Default
/// `idle` renders dormant (transparent fill, just the muted border).
struct TabGlowOverlay<S: Shape>: View {
    let shape: S
    let segments: [TabSegment]
    let isExpanded: Bool
    let edge: FloatingPanelEdge

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // segments 空 / isExpanded → dormant (无 fill 无分割线), 跟今天行为一致
        if segments.isEmpty || isExpanded {
            shape
                .stroke(TabFillSpec.dormant.borderColor, lineWidth: TabFillSpec.dormant.borderWidth)
                .animation(.easeOut(duration: 0.3), value: isExpanded)
                .allowsHitTesting(false)
        } else {
            segmentedBody
        }
    }

    private var segmentedBody: some View {
        let hasAnyNeedsInput = segments.contains(where: \.needsInput)
        let specs = segments.map { segment in
            specFor(segment: segment, hasAnyNeedsInput: hasAnyNeedsInput)
        }
        let anyPulses = specs.contains(where: \.pulses)
        return GeometryReader { proxy in
            let rects = TabSegmenter.rects(
                in: proxy.size,
                count: segments.count,
                edge: edge
            )
            TimelineView(.animation(paused: !anyPulses)) { context in
                renderedTab(specs: specs, rects: rects, size: proxy.size, now: context.date)
            }
        }
        .animation(.easeOut(duration: 0.25), value: segments)
        .animation(.easeOut(duration: 0.3), value: isExpanded)
        .allowsHitTesting(false)
    }

    private func specFor(segment: TabSegment, hasAnyNeedsInput: Bool) -> TabFillSpec {
        if segment.needsInput {
            return TabFillSpec.needsInputSpec(reduceMotion: reduceMotion)
        } else if hasAnyNeedsInput {
            return TabFillSpec.spec(for: segment.displayState).desaturated(by: 0.5)
        } else if segment.isForeground {
            return TabFillSpec.spec(for: segment.displayState).desaturated(by: 0.7)
        } else {
            return TabFillSpec.spec(for: segment.displayState)
        }
    }

    private func renderedTab(specs: [TabFillSpec], rects: [CGRect], size: CGSize, now: Date) -> some View {
        ZStack {
            // N 段填充, mask 到外层 shape 让圆角自然继承
            ForEach(0..<specs.count, id: \.self) { i in
                segmentFill(spec: specs[i], rect: rects[i], now: now)
            }
            .clipShape(shape)

            // Overflow 段叠加层: 水平/竖向 hairlines + 居中 +N 字样, 让聚合
            // 段视觉上跟独立段拉开差距。spec 2026-05-28 §1a。
            ForEach(0..<segments.count, id: \.self) { i in
                if segments[i].isOverflow {
                    overflowOverlay(segment: segments[i], rect: rects[i])
                }
            }
            .clipShape(shape)

            // 边框 — 跟"最显眼"的段一致 (优先 needsInput 段, 否则第 1 段)
            let borderSpec = specs.first(where: \.pulses) ?? specs.first ?? .dormant
            shape
                .stroke(borderSpec.borderColor, lineWidth: borderSpec.borderWidth)

            // 段间分割线, N-1 条; spec §3.7
            ForEach(1..<rects.count, id: \.self) { i in
                dividerLine(at: rects[i].origin, in: size)
            }

            // 拖拽提示 hairline (segmented 模式专属, 跟段填充在同一层 clip)
            dragHandleHint(in: size)
        }
    }

    @ViewBuilder
    private func segmentFill(spec: TabFillSpec, rect: CGRect, now: Date) -> some View {
        if spec.fillVisible {
            let pulseAlpha = spec.pulses
                ? lerp(0.75, 1.0, pulsePhase(now: now, duration: spec.pulseDuration))
                : 1.0
            let gradient = LinearGradient(
                stops: [
                    .init(color: spec.color.opacity(spec.saturatedAlpha * pulseAlpha), location: 0),
                    .init(color: spec.color.opacity(spec.fadedAlpha * pulseAlpha),     location: 1),
                ],
                startPoint: edge.fillStart,
                endPoint:   edge.fillEnd
            )
            Rectangle()
                .fill(gradient)
                .frame(width: rect.size.width, height: rect.size.height)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    /// Visual differentiation for an aggregated overflow segment:
    /// (A) `min(overflowCount + 1, 4)` hairlines spanning the cross axis,
    ///     evenly spaced along the along-edge axis — like multiple sheets
    ///     of paper stacked together; (B) a centered "+N" monospace label
    ///     telling the viewer how many sessions are aggregated here.
    /// spec 2026-05-28 §1a。
    @ViewBuilder
    private func overflowOverlay(segment: TabSegment, rect: CGRect) -> some View {
        // 线条 = overflow 段内的分隔条 (跟整条 bar 的 dividerLine 同一套
        // 语义), 把 overflow 切成 +N 个"小框": N 框 = N-1 条线。+3 →
        // 2 条线 → 3 个框, 一眼能数对。早期试过 N+1 / N 都跟 +N 数字
        // 对不上, 这才是用户的心智模型。封顶 4 线 (= 5 框) 控制密度。
        let lineCount = min(max(segment.overflowCount - 1, 0), 4)
        let labelFontSize: CGFloat = edge.isVertical ? 8 : 9
        ZStack {
            // (A) hairlines: 始终水平 (沿 width 跨满, 沿 height 均分), 不管
            // edge 朝向。"叠层纸张" 的视觉只有在水平条状的情况下才读得对;
            // 把竖向条放到水平 bar 上会让叠层段看起来像被压缩的多个小段
            // (跟段间分割线视觉冲突), 反而误导读者。颜色 Color.black.opacity(0.18)。
            ForEach(0..<lineCount, id: \.self) { i in
                let t = CGFloat(i + 1) / CGFloat(lineCount + 1)
                Rectangle()
                    .fill(Color.black.opacity(0.18))
                    .frame(width: rect.size.width, height: 0.5)
                    .position(x: rect.midX, y: rect.minY + rect.height * t)
            }
            // (B) +N 字样
            Text("+\(segment.overflowCount)")
                .font(.sora(labelFontSize, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.95))
                .shadow(color: Color.black.opacity(0.6), radius: 1, y: 1)
                .position(x: rect.midX, y: rect.midY)
        }
    }

    @ViewBuilder
    private func dividerLine(at origin: CGPoint, in size: CGSize) -> some View {
        // 垂直 edge 时分割线是水平的 (origin.y 是段顶); 水平 edge 时
        // 分割线是竖直的 (origin.x 是段左)。粗细 0.5pt, 颜色 stxStroke.opacity(0.6)。
        // 用 size 的中点作为 .position 的另一轴, 避免 Rectangle 中心位于 0
        // 导致半根分割线溢出 tab 边界。
        switch edge {
        case .left, .right:
            Rectangle()
                .fill(Color.stxStroke.opacity(0.6))
                .frame(width: size.width, height: 0.5)
                .position(x: size.width / 2, y: origin.y)
        case .top, .bottom:
            Rectangle()
                .fill(Color.stxStroke.opacity(0.6))
                .frame(width: 0.5, height: size.height)
                .position(x: origin.x, y: size.height / 2)
        }
    }

    /// A single thin hairline near the "trailing" end of the bar's long
    /// axis — top for vertical edges, far-from-screen end for horizontal
    /// edges — signaling that the bar is draggable. Painted inside the
    /// segmented branch only, on top of the segment fills.
    /// spec 2026-05-28 §1b。
    @ViewBuilder
    private func dragHandleHint(in size: CGSize) -> some View {
        let insetFromEdge: CGFloat = 4
        switch edge {
        case .left, .right:
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: size.width * 0.5, height: 0.5)
                .position(x: size.width / 2, y: insetFromEdge)
        case .top:
            // top dock: bar 顶贴屏幕顶 -> hint 沿长轴(x)放在 bar 右侧 (large x)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.5, height: size.height * 0.5)
                .position(x: size.width - insetFromEdge, y: size.height / 2)
        case .bottom:
            // bottom dock: bar 底贴屏幕底 -> hint 沿长轴(x)放在 bar 左侧 (small x)
            Rectangle()
                .fill(Color.white.opacity(0.22))
                .frame(width: 0.5, height: size.height * 0.5)
                .position(x: insetFromEdge, y: size.height / 2)
        }
    }

    private func pulsePhase(now: Date, duration: TimeInterval) -> Double {
        guard duration > 0 else { return 0.5 }
        let t = now.timeIntervalSinceReferenceDate
        return sin(t * .pi * 2 / duration) * 0.5 + 0.5
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }
}

// MARK: - Spec

/// Frozen visual parameters for one display state. Top-level so static
/// constants don't bump into the generic-type stored-static restriction.
struct TabFillSpec {
    let color: Color
    let saturatedAlpha: Double   // alpha at the desktop-facing end of the gradient
    let fadedAlpha: Double       // alpha at the screen-edge end of the gradient
    let fillVisible: Bool        // false for dormant — skips the gradient layer entirely
    let borderColor: Color
    let borderWidth: CGFloat
    let pulses: Bool
    let pulseDuration: TimeInterval

    /// No state signal. Same look as the legacy static border — a quiet
    /// muted line, no fill.
    static let dormant = TabFillSpec(
        color: .clear,
        saturatedAlpha: 0,
        fadedAlpha: 0,
        fillVisible: false,
        borderColor: Color.stxStroke,
        borderWidth: 1,
        pulses: false,
        pulseDuration: 1
    )

    /// Map a ``LiveSession/DisplayState`` to its visual spec. Colour
    /// choices come from the v2 mockup the user approved — see the
    /// `event-colors-v2.html` brainstorming artefact for the rationale.
    static func spec(for state: LiveSession.DisplayState) -> TabFillSpec {
        switch state {
        case .idle, .sleeping:
            return .dormant
        case .thinking:
            return fillSpec(color: .stxThinking)
        case .working:
            return fillSpec(color: .stxWorking)
        case .juggling:
            return fillSpec(color: .stxJuggling)
        case .attention:
            return fillSpec(color: .stxAttention)
        case .sweeping:
            return fillSpec(color: .stxSweeping, saturated: 0.7, faded: 0.10)
        case .error:
            return TabFillSpec(
                color: .stxError,
                saturatedAlpha: 0.85,
                fadedAlpha: 0.30,
                fillVisible: true,
                borderColor: .stxError,
                borderWidth: 1.5,
                pulses: false,
                pulseDuration: 1
            )
        }
    }

    /// Urgent overlay applied when any visible session has a pending
    /// permission request. Reduce Motion collapses the pulse to a
    /// steady saturated wash so the colour signal survives.
    static func needsInputSpec(reduceMotion: Bool) -> TabFillSpec {
        TabFillSpec(
            color: .stxError,
            saturatedAlpha: 0.95,
            fadedAlpha: 0.25,
            fillVisible: true,
            borderColor: .stxError,
            borderWidth: 1.5,
            pulses: !reduceMotion,
            pulseDuration: 0.6
        )
    }

    private static func fillSpec(color: Color, saturated: Double = 0.85, faded: Double = 0.15) -> TabFillSpec {
        TabFillSpec(
            color: color,
            saturatedAlpha: saturated,
            fadedAlpha: faded,
            fillVisible: true,
            borderColor: color.opacity(0.7),
            borderWidth: 1.2,
            pulses: false,
            pulseDuration: 1
        )
    }

    /// 把 saturated/faded alpha 与 border opacity 按 `factor` 降一档,
    /// 让 needsInput 段成为视觉焦点。原 spec 不变。
    /// 见 spec §3.4 / docs/superpowers/specs/2026-05-26-tab-segmented-glow-design.md
    func desaturated(by factor: Double = 0.5) -> TabFillSpec {
        TabFillSpec(
            color: color,
            saturatedAlpha: saturatedAlpha * factor,
            fadedAlpha: fadedAlpha * factor,
            fillVisible: fillVisible,
            borderColor: borderColor.opacity(factor),
            borderWidth: borderWidth,
            pulses: false,
            pulseDuration: pulseDuration
        )
    }
}

// MARK: - Edge → gradient orientation

fileprivate extension FloatingPanelEdge {
    /// Where the saturated end of the gradient lives. Always on the
    /// desktop-facing side of the tab so the colour catches your eye in
    /// the same direction your other windows live.
    var fillStart: UnitPoint {
        switch self {
        case .left:   .trailing
        case .right:  .leading
        case .top:    .bottom
        case .bottom: .top
        }
    }
    /// Faded end, at the screen-edge side.
    var fillEnd: UnitPoint {
        switch self {
        case .left:   .leading
        case .right:  .trailing
        case .top:    .top
        case .bottom: .bottom
        }
    }
}

// MARK: - Color tokens
//
// Defined here rather than in `Theme.swift` because they're scoped to the
// floating tab's state encoding. If a third surface ever needs them, hoist.

// "Six Quadrants" palette — 6 状态色铺满色相环, 相邻对至少 60° hue 距离,
// 且亮度也错开。原 v2 palette (#FF9F1C / #40C864) 的 orange 跟 green 在
// fade 端只剩色相差容易糊到一起; v3 这套靠 hue + 亮度 + 饱和 三层差异
// 拉开任意两状态。见 docs/superpowers/specs/2026-05-28-floating-tab-palette-mockups.html
fileprivate extension Color {
    /// thinking — UserPromptSubmit ("just received your prompt, model is reasoning").
    static let stxThinking = Color(red: 0.23, green: 0.51, blue: 0.96)   // #3B82F6
    /// working — PreToolUse / PostToolUse / SubagentStop ("executing").
    static let stxWorking  = Color(red: 1.00, green: 0.48, blue: 0.10)   // #FF7A1A
    /// juggling — SubagentStart ("delegating to subagent").
    static let stxJuggling = Color(red: 0.77, green: 0.34, blue: 0.88)   // #C557E0
    /// attention — Stop / PostCompact ("turn finished, look at me").
    static let stxAttention = Color(red: 0.08, green: 0.77, blue: 0.63)  // #14C4A1
    /// sweeping — PreCompact ("compacting context"). Muted gray-blue 跟
    /// thinking blue 完全分开, 视觉上像 "清理中" 的中性色。
    static let stxSweeping = Color(red: 0.48, green: 0.54, blue: 0.63)   // #7B8AA0
    /// error — PostToolUseFailure / StopFailure. Also reused for the
    /// urgent needsInput overlay.
    static let stxError    = Color(red: 0.94, green: 0.27, blue: 0.27)   // #EF4444
}

#if DEBUG
#Preview("All states") {
    let shape = RoundedRectangle(cornerRadius: 12)
    let cases: [(label: String, segment: TabSegment)] = [
        ("idle",      .init(id: "i", displayState: .idle,      needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("thinking",  .init(id: "t", displayState: .thinking,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("working",   .init(id: "w", displayState: .working,   needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("juggling",  .init(id: "j", displayState: .juggling,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("attention", .init(id: "a", displayState: .attention, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("sweeping",  .init(id: "s", displayState: .sweeping,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("error",     .init(id: "e", displayState: .error,     needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false)),
        ("needsIn",   .init(id: "n", displayState: .working,   needsInput: true,  isOverflow: false, overflowCount: 0, isForeground: false)),
    ]
    return HStack(spacing: 24) {
        ForEach(cases, id: \.label) { item in
            VStack(spacing: 6) {
                ZStack {
                    shape
                        .fill(.regularMaterial)
                        .frame(width: 16, height: 110)
                    shape
                        .frame(width: 16, height: 110)
                        .overlay(
                            TabGlowOverlay(
                                shape: shape,
                                segments: [item.segment],
                                isExpanded: false,
                                edge: .right
                            )
                        )
                }
                .frame(width: 80)
                Text(item.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(40)
    .background(Color(white: 0.12))
    .preferredColorScheme(.dark)
}

#Preview("Segmented") {
    let shape = RoundedRectangle(cornerRadius: 12)
    let cases: [(label: String, segments: [TabSegment])] = [
        ("N=1", [
            .init(id: "a", displayState: .working, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
        ]),
        ("N=2", [
            .init(id: "a", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "b", displayState: .working,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
        ]),
        ("N=3", [
            .init(id: "a", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "b", displayState: .working,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "c", displayState: .error,    needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
        ]),
        ("N=5 (满)", [
            .init(id: "a", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "b", displayState: .working,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "c", displayState: .juggling, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "d", displayState: .attention,needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "e", displayState: .sweeping, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
        ]),
        ("N=8 (溢出)", [
            .init(id: "a", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "b", displayState: .working,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "c", displayState: .juggling, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "d", displayState: .attention,needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "overflow", displayState: .error, needsInput: false, isOverflow: true, overflowCount: 4, isForeground: false),
        ]),
        ("N=3 + needsInput[1]", [
            .init(id: "a", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "b", displayState: .working,  needsInput: true,  isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "c", displayState: .error,    needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
        ]),
        ("3 FG only", [
            .init(id: "fg1", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: true),
            .init(id: "fg2", displayState: .working,  needsInput: false, isOverflow: false, overflowCount: 0, isForeground: true),
            .init(id: "fg3", displayState: .error,    needsInput: false, isOverflow: false, overflowCount: 0, isForeground: true),
        ]),
        ("mixed BG+FG", [
            .init(id: "bg1", displayState: .juggling, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "bg2", displayState: .attention,needsInput: false, isOverflow: false, overflowCount: 0, isForeground: false),
            .init(id: "fg1", displayState: .thinking, needsInput: false, isOverflow: false, overflowCount: 0, isForeground: true),
        ]),
    ]
    return HStack(spacing: 24) {
        ForEach(cases, id: \.label) { item in
            VStack(spacing: 6) {
                ZStack {
                    shape
                        .fill(.regularMaterial)
                        .frame(width: 24, height: 200)
                    shape
                        .frame(width: 24, height: 200)
                        .overlay(
                            TabGlowOverlay(
                                shape: shape,
                                segments: item.segments,
                                isExpanded: false,
                                edge: .right
                            )
                        )
                }
                .frame(width: 80)
                Text(item.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
    .padding(40)
    .background(Color(white: 0.12))
    .preferredColorScheme(.dark)
}
#endif
