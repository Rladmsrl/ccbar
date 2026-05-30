import SwiftUI

struct FloatingStatsPanelView: View {
    @Environment(AppEnvironment.self) private var env

    let state: FloatingStatsPanelState
    var onHoverChanged: (Bool) -> Void
    var onSegmentHoverChange: (Int?) -> Void
    var onDragBegan: (CGPoint) -> Void
    var onDragMoved: (CGPoint) -> Void
    var onDragEnded: (CGPoint) -> Void

    var body: some View {
        let edge = state.edge
        // 在 body 顶层显式 read, 把 segmentCap 登记为 SwiftUI body 的直接
        // dependency。否则 Observation 在 GeometryReader closure / helper
        // function 里的 read 不一定能触发 body 重求值, 改 Stepper 后悬浮
        // tab 不会实时响应。同样的值作为参数传给 panelSurface。
        let cap = env.preferences.floatingTabSegmentCap
        GeometryReader { proxy in
            panelSurface(edge: edge, cap: cap, visibleSize: proxy.size)
        }
        .font(.sora(13))
        .tint(.stxAccent)
        .animation(.easeOut(duration: 0.16), value: state.edge)
        .animation(.easeOut(duration: 0.14), value: state.edgeReleaseProgress)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CCBar floating tab")
    }

    private func panelSurface(edge: FloatingPanelEdge, cap: Int, visibleSize: CGSize) -> some View {
        let currentSize = CGSize(
            width: max(visibleSize.width, 1),
            height: max(visibleSize.height, 1)
        )
        let shape = FloatingTabShape(
            edge: edge,
            cornerRadius: state.isExpanded ? 18 : 24,
            edgeReleaseProgress: state.edgeReleaseProgress
        )
        let collapsedSize = FloatingPanelGeometry.size(edge: edge, expanded: false)
        let sessions = env.sessionRegistry.floatingTabSessions
        let actionModel = FloatingSessionActionPresenter.makeModel(
            sessions: sessions,
            unreadDoneSessions: env.sessionRegistry.unreadDoneSessions
        )
        let segmentSessions = actionModel.segmentSessions
        let segments = TabSegmenter.segmentsPreservingForeground(from: segmentSessions, cap: cap)

        return ZStack(alignment: edge.dockedContentAlignment) {
            if state.expandedContentPhase.mountsExpandedContent {
                expandedContent(model: actionModel)
                    .opacity(state.expandedContentPhase.expandedContentOpacity)
                    .animation(.easeOut(duration: FloatingStatsContentAnimation.collapseFadeDuration), value: state.expandedContentPhase)
            }

            if state.showsCollapsedContent {
                collapsedContent(edge: edge, size: collapsedSize, sessions: segmentSessions)
                    .frame(width: collapsedSize.width, height: collapsedSize.height)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.1), value: state.showsCollapsedContent)
        .animation(.easeOut(duration: 0.16), value: state.isExpanded)
        .frame(width: currentSize.width, height: currentSize.height)
        .background {
            shape.fill(.regularMaterial)
        }
        .clipShape(shape)
        .overlay(
            TabGlowOverlay(
                shape: shape,
                segments: segments,
                isExpanded: state.isExpanded,
                edge: edge
            )
        )
        .overlay(
            SegmentHoverTracker(
                segments: segments,
                edge: edge,
                isExpanded: state.isExpanded,
                onSegmentHover: { idx in
                    onSegmentHoverChange(idx)
                }
            )
        )
        .overlay(dragHandle)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.dockedContentAlignment)
        .contentShape(Rectangle())
        .overlay(FloatingHoverTracker(onHoverChanged: onHoverChanged).accessibilityHidden(true))
    }

    private func collapsedContent(edge: FloatingPanelEdge, size: CGSize, sessions: [LiveSession]) -> some View {
        let title = L10n.string("floating.tab.title", defaultValue: "Claude agents")
        return Group {
            if sessions.isEmpty {
                if edge.isVertical {
                    sideCollapsedTitle(title, edge: edge, size: size)
                } else {
                    horizontalCollapsedTitle(title)
                }
            } else {
                // 折叠条本身(被 TabGlowOverlay 绘制)就是内容。
                // collapsedContent 这一层不再叠任何文字 / badge / hint —— drag
                // handle hint 由 TabGlowOverlay 自己画。Color.clear 占位承载
                // a11y label, 让 VoiceOver 仍能朗读会话总数 + 最高优先级状态。
                Color.clear
                    .accessibilityLabel(L10n.format(
                        "floating.tab.badge.a11y",
                        defaultValue: "%d Claude sessions, status %@",
                        sessions.count,
                        sessions.dominantBadge?.rawValue ?? LiveSession.Badge.idle.rawValue
                    ))
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Metrics.collapsedContentPadding)
            .accessibilityHint("Hover to expand. Drag to snap to another screen edge.")
    }

    private func horizontalCollapsedTitle(_ title: String) -> some View {
        Text(title)
            .font(.sora(13, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func sideCollapsedTitle(_ title: String, edge: FloatingPanelEdge, size: CGSize) -> some View {
        let innerSize = CGSize(
            width: max(size.width - Metrics.collapsedContentPadding * 2, 1),
            height: max(size.height - Metrics.collapsedContentPadding * 2, 1)
        )

        return sideCollapsedTitleText(title)
            .frame(width: innerSize.height, height: innerSize.width)
            .rotationEffect(sideTitleRotation(for: edge))
            .frame(width: innerSize.width, height: innerSize.height)
            .accessibilityLabel(title)
    }

    private func sideCollapsedTitleText(_ title: String) -> some View {
        Text(title)
            .font(.sora(14, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    private func sideTitleRotation(for edge: FloatingPanelEdge) -> Angle {
        switch edge {
        case .right: .degrees(-90)
        case .left: .degrees(90)
        case .top, .bottom: .zero
        }
    }

    @ViewBuilder
    private func expandedContent(model: FloatingSessionActionListModel) -> some View {
        if let pending = env.permissionStore.pending.first {
            PermissionBubbleView(
                request: pending,
                pendingCount: env.permissionStore.pending.count,
                allowShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutAllow),
                denyShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutDeny),
                alwaysShortcut: PermissionShortcutSpec.parse(env.preferences.permissionShortcutAlways),
                errorMessage: env.permissionStore.lastErrorMessage,
                onAllow: { handlePermissionAllow(pending) },
                onDeny: { handlePermissionDeny(pending) },
                onAlways: { handlePermissionAlways(pending, suggestion: $0) }
            )
        } else {
            FloatingSessionActionList(model: model)
                .transition(.opacity)
        }
    }

    private func handlePermissionAllow(_ request: PermissionRequest) {
        env.permissionStore.resolve(request.id, decision: .allow(message: nil))
    }

    private func handlePermissionDeny(_ request: PermissionRequest) {
        env.permissionStore.resolve(request.id, decision: .deny(message: nil))
    }

    private func handlePermissionAlways(_ request: PermissionRequest, suggestion: PermissionSuggestion) {
        do {
            _ = try env.permissionAllowRuleWriter.apply(suggestions: [suggestion])
            env.permissionStore.noteAddedAllowRule(suggestion.displayLabel)
        } catch {
            Log.permission.error("failed to write allow rule: \(error.localizedDescription, privacy: .public)")
            env.permissionStore.noteError(error.localizedDescription)
            return
        }
        env.permissionStore.resolve(request.id, decision: .allow(message: nil))
    }

    private var dragHandle: some View {
        FloatingDragHandle(
            isExpanded: state.isExpanded,
            onDragBegan: onDragBegan,
            onDragMoved: onDragMoved,
            onDragEnded: onDragEnded
        )
        .accessibilityHidden(true)
    }

    private enum Metrics {
        static let collapsedContentPadding: CGFloat = 8
    }
}

private extension FloatingPanelEdge {
    var dockedContentAlignment: Alignment {
        switch self {
        case .left:
            .leading
        case .right:
            .trailing
        case .top:
            .top
        case .bottom:
            .bottom
        }
    }
}

private struct FloatingTabShape: Shape {
    let edge: FloatingPanelEdge
    let cornerRadius: CGFloat
    var edgeReleaseProgress: CGFloat

    var animatableData: CGFloat {
        get { edgeReleaseProgress }
        set { edgeReleaseProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(cornerRadius, min(rect.width, rect.height) / 2)
        let dockedRadius = r * min(max(edgeReleaseProgress, 0), 1)
        let radii = cornerRadii(exposedRadius: r, dockedRadius: dockedRadius)
        return roundedRectPath(in: rect, radii: radii)
    }

    private func cornerRadii(exposedRadius: CGFloat, dockedRadius: CGFloat) -> CornerRadii {
        switch edge {
        case .right:
            CornerRadii(
                topLeft: exposedRadius,
                topRight: dockedRadius,
                bottomRight: dockedRadius,
                bottomLeft: exposedRadius
            )
        case .left:
            CornerRadii(
                topLeft: dockedRadius,
                topRight: exposedRadius,
                bottomRight: exposedRadius,
                bottomLeft: dockedRadius
            )
        case .top:
            CornerRadii(
                topLeft: dockedRadius,
                topRight: dockedRadius,
                bottomRight: exposedRadius,
                bottomLeft: exposedRadius
            )
        case .bottom:
            CornerRadii(
                topLeft: exposedRadius,
                topRight: exposedRadius,
                bottomRight: dockedRadius,
                bottomLeft: dockedRadius
            )
        }
    }

    private func roundedRectPath(in rect: CGRect, radii: CornerRadii) -> Path {
        let maximumRadius = min(rect.width, rect.height) / 2
        let topLeft = min(radii.topLeft, maximumRadius)
        let topRight = min(radii.topRight, maximumRadius)
        let bottomRight = min(radii.bottomRight, maximumRadius)
        let bottomLeft = min(radii.bottomLeft, maximumRadius)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - topRight, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + topRight), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottomRight))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - bottomRight, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottomLeft, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bottomLeft), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeft))
        path.addQuadCurve(to: CGPoint(x: rect.minX + topLeft, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))

        path.closeSubpath()
        return path
    }

    private struct CornerRadii {
        var topLeft: CGFloat
        var topRight: CGFloat
        var bottomRight: CGFloat
        var bottomLeft: CGFloat
    }
}

#if DEBUG
#Preview("Floating tab") {
    VStack(spacing: 24) {
        FloatingStatsPanelView(
            state: {
                let state = FloatingStatsPanelState()
                state.edge = .right
                return state
            }(),
            onHoverChanged: { _ in },
            onSegmentHoverChange: { _ in },
            onDragBegan: { _ in },
            onDragMoved: { _ in },
            onDragEnded: { _ in }
        )
        .environment(AppEnvironment.preview())

        FloatingStatsPanelView(
            state: {
                let state = FloatingStatsPanelState()
                state.edge = .right
                state.isExpanded = true
                state.expandedContentPhase = .visible
                state.showsCollapsedContent = false
                return state
            }(),
            onHoverChanged: { _ in },
            onSegmentHoverChange: { _ in },
            onDragBegan: { _ in },
            onDragMoved: { _ in },
            onDragEnded: { _ in }
        )
        .environment(AppEnvironment.preview())
    }
    .padding(40)
}
#endif
