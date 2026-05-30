import CoreGraphics
import Foundation

/// 一个 floating tab 段的渲染状态。由 `TabSegmenter` 从 `[LiveSession]`
/// 派生,`TabGlowOverlay` 消费。`isOverflow` 段聚合多个 session。
struct TabSegment: Sendable, Equatable {
    /// `session.id` 或溢出段固定的 `"overflow"`
    let id: String
    let displayState: LiveSession.DisplayState
    let needsInput: Bool
    /// 仅在 N > cap 时, 最后一段为 true
    let isOverflow: Bool
    /// `isOverflow == false` 时永远 0; `true` 时 = 被聚合的 session 数 (>= 2)
    let overflowCount: Int
    /// True 当该段对应的 session.kind == .foreground (terminal claude)。
    /// `TabGlowOverlay` 用这个把 FG 段轻调淡, 让 BG 段视觉占主导。
    /// 溢出段沿用 `max(updatedAt)` session 的 kind。spec §Amendment 2026-05-26。
    let isForeground: Bool
}

/// `TabSegment` 派生和 tab 内几何切分的纯函数集合。无 SwiftUI 依赖,
/// 单测覆盖详见 `TabSegmenterTests`。
enum TabSegmenter {
    /// 把 visibleSessions 折成最多 `cap` 段。
    ///
    /// - 当 `sessions.count <= cap`: 每段对应一个 session, 顺序保留
    /// - 当 `sessions.count > cap`: 前 `cap - 1` 段对应前 `cap - 1` 个
    ///   session, 最后一段是溢出聚合段 (id == "overflow",
    ///   displayState 取溢出区 `max(updatedAt)` session 的 displayState,
    ///   needsInput 取溢出区任一 session needsInput, overflowCount =
    ///   sessions.count - (cap - 1))
    /// - `sessions.isEmpty || cap <= 0` 都返回 `[]`
    static func segments(
        from sessions: [LiveSession],
        cap: Int
    ) -> [TabSegment] {
        guard cap > 0, !sessions.isEmpty else { return [] }
        if sessions.count <= cap {
            return sessions.map(segment)
        }
        // N > cap: 前 (cap - 1) 段独立; 最后一段聚合 sessions[cap-1..<N]
        let independent = sessions.prefix(cap - 1).map(segment)
        let overflowRegion = sessions.suffix(from: cap - 1) // 闭区间 [cap-1, N-1]
        return independent + [overflowSegment(from: overflowRegion)]
    }

    /// Floating-tab policy: all foreground sessions must be individually
    /// visible. The density cap still groups non-foreground/actionable extras
    /// when there is not enough room.
    static func segmentsPreservingForeground(
        from sessions: [LiveSession],
        cap: Int
    ) -> [TabSegment] {
        guard !sessions.isEmpty else { return [] }

        let foreground = sessions.filter { $0.kind == .foreground }
        guard !foreground.isEmpty else {
            return segments(from: sessions, cap: cap)
        }
        guard cap > 0 else {
            return foreground.map(segment)
        }
        guard sessions.count > cap else {
            return sessions.map(segment)
        }

        let nonForeground = sessions.filter { $0.kind != .foreground }
        guard !nonForeground.isEmpty else {
            return foreground.map(segment)
        }

        let independentNonForegroundCount = max(cap - foreground.count - 1, 0)
        let independentNonForeground = nonForeground.prefix(independentNonForegroundCount)
        let independentNonForegroundIds = Set(independentNonForeground.map(\.id))
        let independent = sessions
            .filter { session in
                session.kind == .foreground || independentNonForegroundIds.contains(session.id)
            }
            .map(segment)
        let overflowRegion = nonForeground.suffix(from: independentNonForegroundCount)
        return independent + [overflowSegment(from: overflowRegion)]
    }

    /// 把 tab 总 size 按 `count` 段均分, 返回每段的 sub-rect。
    /// 垂直 edge (.left/.right) 沿 height 切; 水平 edge (.top/.bottom)
    /// 沿 width 切。`count <= 0` 返回 `[]`; `count == 1` 返回单个等同
    /// 整 size 的 rect。
    static func rects(
        in size: CGSize,
        count: Int,
        edge: FloatingPanelEdge
    ) -> [CGRect] {
        guard count > 0 else { return [] }
        if count == 1 {
            return [CGRect(origin: .zero, size: size)]
        }
        let dividend: CGFloat
        let alongVertical: Bool
        switch edge {
        case .left, .right:
            dividend = size.height
            alongVertical = true
        case .top, .bottom:
            dividend = size.width
            alongVertical = false
        }
        let perSegment = dividend / CGFloat(count)
        return (0..<count).map { i in
            let offset = perSegment * CGFloat(i)
            if alongVertical {
                return CGRect(
                    x: 0,
                    y: offset,
                    width: size.width,
                    height: perSegment
                )
            } else {
                return CGRect(
                    x: offset,
                    y: 0,
                    width: perSegment,
                    height: size.height
                )
            }
        }
    }

    private static func segment(for session: LiveSession) -> TabSegment {
        TabSegment(
            id: session.id,
            displayState: session.displayState,
            needsInput: session.needsInput,
            isOverflow: false,
            overflowCount: 0,
            isForeground: session.kind == .foreground
        )
    }

    private static func overflowSegment<C: Collection>(from sessions: C) -> TabSegment
        where C.Element == LiveSession {
        let mostRecent = sessions.max(by: { $0.updatedAt < $1.updatedAt })
            ?? sessions.first!
        return TabSegment(
            id: "overflow",
            displayState: mostRecent.displayState,
            needsInput: sessions.contains(where: \.needsInput),
            isOverflow: true,
            overflowCount: sessions.count,
            isForeground: mostRecent.kind == .foreground
        )
    }
}
