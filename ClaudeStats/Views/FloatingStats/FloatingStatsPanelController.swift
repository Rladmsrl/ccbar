import AppKit
import Observation
import QuartzCore
import SwiftUI

@MainActor
final class FloatingStatsPanelController {
    private enum DragState {
        case idle
        case pending(startMouse: CGPoint, startFrame: CGRect)
        case active(startMouse: CGPoint, startFrame: CGRect)

        var isDragging: Bool {
            switch self {
            case .idle: false
            case .pending, .active: true
            }
        }
    }

    private enum Placement {
        case docked
        case detached(frame: CGRect)

        var isDocked: Bool {
            switch self {
            case .docked: true
            case .detached: false
            }
        }
    }

    private enum FrameAnimationStyle {
        case standard
        case collapse

        var duration: TimeInterval {
            switch self {
            case .standard:
                FloatingStatsContentAnimation.panelExpandDuration
            case .collapse:
                FloatingStatsContentAnimation.panelCollapseDuration
            }
        }

        var timingFunction: CAMediaTimingFunction {
            switch self {
            case .standard:
                CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            case .collapse:
                CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
            }
        }
    }

    private weak var environment: AppEnvironment?
    private weak var preferences: Preferences?
    private let state = FloatingStatsPanelState()

    private var panel: NSPanel?
    private var placement: Placement = .docked
    private var dragState: DragState = .idle
    private var collapseTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var suppressPreferenceSync = false
    private var frameTransitionID = 0
    private var contentTransitionID = 0
    private var contentTransitionTask: Task<Void, Never>?
    private var isApplyingFrame = false
    private var isStarted = false
    private var isHovering = false
    private var requiresExitBeforeReexpand = false

    func start(environment: AppEnvironment) {
        guard !isStarted else { return }
        isStarted = true
        self.environment = environment
        self.preferences = environment.preferences
        state.edge = environment.preferences.floatingTabEdge
        observePreferences()
        syncWithPreferences()
        observeScreenChanges()
        observePermissionStore()
    }

    private func observePermissionStore() {
        guard let environment else { return }
        withObservationTracking {
            _ = environment.permissionStore.pending.count
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePermissionPendingChange()
                self?.observePermissionStore()
            }
        }
    }

    /// Force-expand when a permission lands. Once the queue clears, **always
    /// collapse** rather than resize back to stats — resizing from the
    /// compact permission frame (380×280) into the stats frame (320×360)
    /// while simultaneously swapping the SwiftUI content tree causes a
    /// visible flicker. Collapsing to docked is also what clawd does after a
    /// decision; the user can re-hover to see stats fresh.
    private func handlePermissionPendingChange() {
        guard let environment else { return }
        let hasPending = !environment.permissionStore.pending.isEmpty
        if hasPending {
            collapseTask?.cancel()
            collapseTask = nil
            if !state.isExpanded {
                setExpanded(true, animated: true)
            } else {
                // Already expanded for stats — re-apply the frame so we
                // switch to the compact permission size.
                applyStoredFrame(animated: true)
            }
        } else if state.isExpanded {
            // Bubble dismissed: hop to docked. Skip the normal `isHovering`
            // gate so we don't redraw the stats panel underneath the user's
            // cursor in the same animation frame.
            collapseCurrentPlacement(animated: true)
            // Make the next hover (if any) trigger a fresh expand.
            isHovering = false
            requiresExitBeforeReexpand = true
        }
    }

    /// Called from the SwiftUI root view when the cursor enters or leaves
    /// a tab segment. Non-nil index drives expand; nil indicates the
    /// cursor left the tab/panel and the existing `collapseTask` grace
    /// window applies (`setHovering(false)` chains into `scheduleCollapse`).
    /// Cleared on actual collapse (see `collapseCurrentPlacement`).
    func handleSegmentHover(_ index: Int?) {
        if let index {
            state.hoveredSegmentIndex = index
            // Treat entering a segment as the panel being hovered, so the
            // controller-side collapse task is cancelled and the panel
            // expands if not already.
            setHovering(true, allowsStatsExpand: true)
        } else {
            // Cursor left all segment rects. Reuse the existing
            // setHovering(false) path so the grace window + permission
            // override + drag suppression rules all apply unchanged.
            setHovering(false)
        }
    }

    private func observePreferences() {
        guard let preferences else { return }
        withObservationTracking {
            _ = preferences.floatingTabEnabled
            _ = preferences.floatingTabEdge
            _ = preferences.floatingTabAnchor
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                if self?.suppressPreferenceSync == true {
                    self?.observePreferences()
                    return
                }
                self?.syncWithPreferences()
                self?.observePreferences()
            }
        }
    }

    private func syncWithPreferences() {
        guard let preferences else { return }
        if preferences.floatingTabEnabled {
            environment?.claudeAgents.start()
            placement = .docked
            state.isDocked = true
            setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: false)
            state.edge = preferences.floatingTabEdge
            ensurePanel()
            guard !dragState.isDragging else { return }
            applyStoredFrame(animated: false)
            backfillStoredDisplayIDIfNeeded()
        } else {
            environment?.claudeAgents.stop()
            closePanel()
        }
    }

    /// Older builds did not persist `floatingTabDisplayID`. After the first
    /// `ensurePanel` on a new build, save whichever screen the panel ended up
    /// on so subsequent expand/collapse cycles stay pinned to it. The user
    /// can still relocate the panel by dragging — that path also updates the
    /// stored ID via `persistPlacement`.
    private func backfillStoredDisplayIDIfNeeded() {
        guard let preferences, preferences.floatingTabDisplayID == 0 else { return }
        guard let panel else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(panel.frame.center) })
            ?? bestScreen(for: panel.frame.center)
        let id = screen.displayID
        guard id != 0 else { return }
        preferences.floatingTabDisplayID = id
    }

    private func ensurePanel() {
        guard panel == nil, let environment, let preferences else { return }
        let screen = bestScreen(for: nil)
        let frame = FloatingPanelGeometry.frame(
            edge: preferences.floatingTabEdge,
            anchor: preferences.floatingTabAnchor,
            in: screen.visibleFrame,
            expanded: false
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.title = "CCBar Floating Tab"

        let rootView = FloatingStatsPanelView(
            state: state,
            onHoverChanged: { [weak self] hovering in
                self?.setHovering(hovering)
            },
            onSegmentHoverChange: { [weak self] index in
                self?.handleSegmentHover(index)
            },
            onDragBegan: { [weak self] mouseLocation in
                self?.dragBegan(at: mouseLocation)
            },
            onDragMoved: { [weak self] mouseLocation in
                self?.dragMoved(to: mouseLocation)
            },
            onDragEnded: { [weak self] mouseLocation in
                self?.dragEnded(at: mouseLocation)
            }
        )
        .environment(environment)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.wantsLayer = true
        hostingView.layer?.isOpaque = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
        panel.orderFrontRegardless()
    }

    private func closePanel() {
        state.hoveredSegmentIndex = nil    // hover-preview cleanup; mirror collapseCurrentPlacement
        collapseTask?.cancel()
        collapseTask = nil
        cancelContentTransition()
        panel?.orderOut(nil)
        panel = nil
        placement = .docked
        dragState = .idle
        frameTransitionID += 1
        isApplyingFrame = false
        isHovering = false
        requiresExitBeforeReexpand = false
        state.isExpanded = false
        state.expandedContentPhase = .hidden
        state.showsCollapsedContent = true
        state.isDocked = true
        setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: false)
    }

    private func setHovering(_ hovering: Bool, allowsStatsExpand: Bool = false) {
        guard !dragState.isDragging else { return }
        guard !isApplyingFrame else { return }
        if requiresExitBeforeReexpand {
            if hovering || isMouseInsidePanel() {
                isHovering = false
                return
            }
            requiresExitBeforeReexpand = false
        }
        if !hovering, isMouseInsidePanel() {
            isHovering = true
            return
        }
        isHovering = hovering
        if hovering {
            requiresExitBeforeReexpand = false
            collapseTask?.cancel()
            collapseTask = nil
            if FloatingStatsPanelHoverExpansionPolicy.shouldExpandOnPanelHover(
                hasHoveredSegment: allowsStatsExpand || state.hoveredSegmentIndex != nil,
                hasPendingPermission: environment?.permissionStore.pending.isEmpty == false
            ) {
                setExpanded(true, animated: true)
            }
        } else if state.isExpanded {
            scheduleCollapse()
        } else {
            collapseTask?.cancel()
            collapseTask = nil
        }
    }

    private func scheduleCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        guard !isHovering, !dragState.isDragging else { return }
        guard !isMouseInsidePanel() else {
            isHovering = true
            return
        }
        // Pending permission requests pin the panel open until the user
        // resolves them — collapsing would hide the bubble UI mid-decision.
        if let env = environment, !env.permissionStore.pending.isEmpty { return }
        collapseCurrentPlacement(animated: true)
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        if expanded {
            requiresExitBeforeReexpand = false
            guard !state.isExpanded else {
                restoreExpandedContent(animated: animated)
                environment?.claudeAgents.refreshIfStale()
                return
            }
            environment?.claudeAgents.refreshIfStale()
            state.isExpanded = true
            prepareExpandedContentForReveal(animated: animated)
            applyStoredFrame(expanded: true, animated: animated, animationStyle: .standard)
            return
        }

        guard state.isExpanded else { return }
        if !placement.isDocked {
            dockDetachedPanel(animated: animated)
            return
        }
        collapseDockedPanel(animated: animated)
    }

    private func prepareExpandedContentForReveal(animated: Bool) {
        cancelContentTransition()
        state.showsCollapsedContent = false

        guard animated else {
            state.expandedContentPhase = .visible
            return
        }

        state.expandedContentPhase = .waitingToReveal
        contentTransitionID += 1
        let transitionID = contentTransitionID
        contentTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: FloatingStatsContentAnimation.nanoseconds(for: FloatingStatsContentAnimation.revealInitialDelay)
            )
            guard let self, !Task.isCancelled, self.contentTransitionID == transitionID else { return }
            self.state.expandedContentPhase = .revealing

            try? await Task.sleep(
                nanoseconds: FloatingStatsContentAnimation.nanoseconds(for: FloatingStatsContentAnimation.totalRevealDuration)
            )
            guard !Task.isCancelled, self.contentTransitionID == transitionID else { return }
            self.state.expandedContentPhase = .visible
            self.contentTransitionTask = nil
        }
    }

    private func restoreExpandedContent(animated: Bool) {
        guard state.isExpanded else { return }
        cancelContentTransition()
        state.showsCollapsedContent = false
        switch state.expandedContentPhase {
        case .hidden, .waitingToReveal:
            prepareExpandedContentForReveal(animated: animated)
        case .revealing, .visible:
            break
        case .hiding:
            if animated {
                withAnimation(.easeOut(duration: FloatingStatsContentAnimation.collapseFadeDuration)) {
                    state.expandedContentPhase = .visible
                }
            } else {
                state.expandedContentPhase = .visible
            }
        }
    }

    private func cancelContentTransition() {
        contentTransitionTask?.cancel()
        contentTransitionTask = nil
        contentTransitionID += 1
    }

    private func dragBegan(at mouseLocation: CGPoint) {
        guard let panel else { return }
        collapseTask?.cancel()
        collapseTask = nil
        restoreExpandedContent(animated: false)
        frameTransitionID += 1
        isApplyingFrame = false
        requiresExitBeforeReexpand = false
        switch placement {
        case .docked:
            setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: false)
            dragState = .pending(startMouse: mouseLocation, startFrame: panel.frame)
        case .detached:
            state.isDocked = false
            setEdgeReleaseProgress(FloatingPanelDragMotion.detachedEdgeReleaseProgress, animated: false)
            dragState = .active(startMouse: mouseLocation, startFrame: panel.frame)
        }
    }

    private func dragMoved(to mouseLocation: CGPoint) {
        guard let panel else { return }
        switch dragState {
        case .idle:
            return
        case let .pending(startMouse, startFrame):
            let step = FloatingPanelDragMotion.dragStep(
                startFrame: startFrame,
                startMouse: startMouse,
                currentMouse: mouseLocation,
                isDocked: true
            )
            guard case let .active(nextFrame, edgeReleaseProgress) = step else {
                return
            }
            placement = .detached(frame: nextFrame)
            state.isDocked = false
            setEdgeReleaseProgress(edgeReleaseProgress, animated: true)
            let frame = magneticFrame(for: nextFrame)
            placement = .detached(frame: frame)
            dragState = .active(startMouse: startMouse, startFrame: startFrame)
            panel.setFrame(frame, display: true)
        case let .active(startMouse, startFrame):
            let nextFrame = FloatingPanelDragMotion.frame(
                startFrame: startFrame,
                startMouse: startMouse,
                currentMouse: mouseLocation
            )
            let frame = magneticFrame(for: nextFrame)
            placement = .detached(frame: frame)
            panel.setFrame(frame, display: true)
        }
    }

    private func dragEnded(at mouseLocation: CGPoint) {
        guard let panel, let preferences else { return }
        let wasActive: Bool
        let releaseFrame: CGRect
        switch dragState {
        case .idle:
            return
        case .pending:
            wasActive = false
            releaseFrame = panel.frame
        case .active:
            wasActive = true
            releaseFrame = panel.frame
        }
        dragState = .idle

        guard wasActive else {
            updateHoverAfterDrag(mouseLocation: mouseLocation)
            if !isHovering {
                scheduleCollapse()
            }
            return
        }

        // Use the release-frame center to pick the destination screen — at
        // this point the panel is wherever the user let go, which is the
        // truth we want to remember (the stored displayID may still be from
        // wherever it was previously docked).
        let screen = NSScreen.screens.first(where: { $0.frame.contains(releaseFrame.center) })
            ?? bestScreen(for: releaseFrame.center)
        switch FloatingPanelDragMotion.releasePlacement(for: releaseFrame, in: screen.visibleFrame) {
        case let .docked(edge, anchor):
            placement = .docked
            state.isDocked = true
            setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: true)
            persistPlacement(edge: edge, anchor: anchor, screen: screen, preferences: preferences)
            applyStoredFrame(animated: true)
        case let .detached(frame):
            let detachedFrame = expandedDetachedFrame(from: frame, in: screen.visibleFrame)
            placement = .detached(frame: detachedFrame)
            state.isDocked = false
            setEdgeReleaseProgress(FloatingPanelDragMotion.detachedEdgeReleaseProgress, animated: false)
            state.isExpanded = true
            state.showsCollapsedContent = false
            state.expandedContentPhase = .visible
            if !panel.frame.isApproximatelyEqual(to: detachedFrame) {
                panel.setFrame(detachedFrame, display: true)
            }

            updateHoverAfterDrag(mouseLocation: mouseLocation)
            if !isHovering {
                scheduleCollapse()
            }
        }
    }

    private func persistPlacement(edge: FloatingPanelEdge, anchor: Double, screen: NSScreen, preferences: Preferences) {
        state.edge = edge
        suppressPreferenceSync = true
        preferences.floatingTabEdge = edge
        preferences.floatingTabAnchor = anchor
        preferences.floatingTabDisplayID = screen.displayID
        DispatchQueue.main.async { [weak self] in
            self?.suppressPreferenceSync = false
        }
    }

    private func updateHoverAfterDrag(mouseLocation: CGPoint) {
        isHovering = panel?.frame.contains(mouseLocation) ?? false
    }

    private func applyStoredFrame(animated: Bool) {
        applyStoredFrame(expanded: state.isExpanded, animated: animated)
    }

    private func applyStoredFrame(
        expanded: Bool,
        animated: Bool,
        animationStyle: FrameAnimationStyle = .standard,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let panel, let preferences else { return }
        guard !dragState.isDragging else { return }
        guard placement.isDocked else { return }
        let screen = bestScreen(for: panel.frame.center)
        let edge = preferences.floatingTabEdge
        let compact = expanded && (environment?.permissionStore.pending.isEmpty == false)
        let anchor = FloatingPanelGeometry.clampedAnchor(
            preferences.floatingTabAnchor,
            edge: edge,
            size: FloatingPanelGeometry.size(edge: edge, expanded: expanded, compact: compact),
            in: screen.visibleFrame
        )
        if anchor != preferences.floatingTabAnchor {
            preferences.floatingTabAnchor = anchor
        }
        let frame = FloatingPanelGeometry.frame(
            edge: edge,
            anchor: anchor,
            in: screen.visibleFrame,
            expanded: expanded,
            compact: compact
        )

        state.edge = edge
        state.isDocked = true
        setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: animated)
        if animated {
            setPanelFrame(frame, animated: true, animationStyle: animationStyle, completion: completion)
        } else {
            panel.setFrame(frame, display: true)
            completion?()
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyCurrentPlacementAfterScreenChange(animated: true)
            }
        }
    }

    private func collapseCurrentPlacement(animated: Bool) {
        state.hoveredSegmentIndex = nil    // hover-preview cleanup; spec 2026-05-28
        switch placement {
        case .docked:
            setExpanded(false, animated: animated)
        case .detached:
            dockDetachedPanel(animated: animated)
        }
    }

    private func collapseDockedPanel(animated: Bool) {
        let finishCollapse: @MainActor @Sendable () -> Void = { [weak self] in
            guard let self else { return }
            self.showCollapsedContentForCollapsedFrame()
            self.updateHoverGateAfterDockedCollapse()
        }

        hideExpandedContentBeforePanelCollapse(animated: animated) { [weak self] in
            guard let self else { return }
            self.state.expandedContentPhase = .hidden
            self.state.showsCollapsedContent = false
            self.state.isExpanded = false
            self.applyStoredFrame(expanded: false, animated: animated, animationStyle: .collapse, completion: finishCollapse)
        }
    }

    private func hideExpandedContentBeforePanelCollapse(
        animated: Bool,
        completion: @escaping @MainActor @Sendable () -> Void
    ) {
        cancelContentTransition()
        guard animated, state.expandedContentPhase.mountsExpandedContent else {
            completion()
            return
        }

        contentTransitionID += 1
        let transitionID = contentTransitionID
        withAnimation(.easeOut(duration: FloatingStatsContentAnimation.collapseFadeDuration)) {
            state.expandedContentPhase = .hiding
        }

        contentTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: FloatingStatsContentAnimation.nanoseconds(for: FloatingStatsContentAnimation.collapseFadeDuration)
            )
            guard let self, !Task.isCancelled, self.contentTransitionID == transitionID else { return }
            self.contentTransitionTask = nil
            completion()
        }
    }

    private func showCollapsedContentForCollapsedFrame() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.expandedContentPhase = .hidden
            state.showsCollapsedContent = true
        }
    }

    private func updateHoverGateAfterDockedCollapse() {
        collapseTask?.cancel()
        collapseTask = nil
        isHovering = false
        requiresExitBeforeReexpand = isMouseInsidePanel()
    }

    private func dockDetachedPanel(animated: Bool) {
        guard let panel, let preferences else { return }
        let screen = NSScreen.screens.first(where: { $0.frame.contains(panel.frame.center) })
            ?? bestScreen(for: panel.frame.center)
        let edge = FloatingPanelGeometry.nearestEdge(to: panel.frame.center, in: screen.visibleFrame)
        let size = FloatingPanelGeometry.size(edge: edge, expanded: false)
        let anchor = FloatingPanelGeometry.anchor(for: panel.frame.center, edge: edge, in: screen.visibleFrame, size: size)

        placement = .docked
        state.isDocked = true
        state.isExpanded = false
        state.expandedContentPhase = .hidden
        state.showsCollapsedContent = false
        setEdgeReleaseProgress(FloatingPanelDragMotion.dockedEdgeReleaseProgress, animated: animated)
        persistPlacement(edge: edge, anchor: anchor, screen: screen, preferences: preferences)
        applyStoredFrame(expanded: false, animated: animated, animationStyle: .collapse) { [weak self] in
            self?.showCollapsedContentForCollapsedFrame()
        }
    }

    private func applyCurrentPlacementAfterScreenChange(animated: Bool) {
        guard let panel else { return }
        guard !dragState.isDragging else { return }
        switch placement {
        case .docked:
            applyStoredFrame(animated: animated)
        case .detached:
            let screen = bestScreen(for: panel.frame.center)
            let frame = FloatingPanelDragMotion.clampedFrame(panel.frame, in: screen.visibleFrame)
            placement = .detached(frame: frame)
            setPanelFrame(frame, animated: animated)
        }
    }

    private func magneticFrame(for frame: CGRect) -> CGRect {
        let screen = bestScreen(for: frame.center)
        return FloatingPanelDragMotion.magneticFrame(frame, in: screen.visibleFrame)
    }

    private func expandedDetachedFrame(from frame: CGRect, in visibleFrame: CGRect) -> CGRect {
        guard !state.isExpanded else {
            return FloatingPanelDragMotion.clampedFrame(frame, in: visibleFrame)
        }

        let expandedSize = FloatingPanelGeometry.expandedSize
        let expandedFrame = CGRect(
            x: frame.midX - expandedSize.width / 2,
            y: frame.midY - expandedSize.height / 2,
            width: expandedSize.width,
            height: expandedSize.height
        )
        return FloatingPanelDragMotion.clampedFrame(expandedFrame, in: visibleFrame)
    }

    private func setEdgeReleaseProgress(_ progress: CGFloat, animated: Bool) {
        let clamped = min(max(progress, 0), 1)
        guard state.edgeReleaseProgress != clamped else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.14)) {
                state.edgeReleaseProgress = clamped
            }
        } else {
            state.edgeReleaseProgress = clamped
        }
    }

    private func setPanelFrame(
        _ frame: CGRect,
        animated: Bool,
        animationStyle: FrameAnimationStyle = .standard,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        guard let panel else { return }
        guard animated else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }

        frameTransitionID += 1
        let transitionID = frameTransitionID
        isApplyingFrame = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animationStyle.duration
            context.timingFunction = animationStyle.timingFunction
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                self?.finishFrameTransition(id: transitionID, completion: completion)
            }
        }
    }

    private func finishFrameTransition(id: Int, completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard id == frameTransitionID else { return }
        isApplyingFrame = false
        completion?()
        refreshHoverStateAfterFrameChange()
    }

    private func refreshHoverStateAfterFrameChange() {
        guard !dragState.isDragging else { return }
        if requiresExitBeforeReexpand {
            if isMouseInsidePanel() {
                isHovering = false
                collapseTask?.cancel()
                collapseTask = nil
                return
            }
            requiresExitBeforeReexpand = false
        }
        if isMouseInsidePanel() {
            isHovering = true
            collapseTask?.cancel()
            collapseTask = nil
        } else {
            isHovering = false
            if state.isExpanded {
                scheduleCollapse()
            }
        }
    }

    private func isMouseInsidePanel() -> Bool {
        panel?.frame.contains(NSEvent.mouseLocation) ?? false
    }

    private func bestScreen(for point: CGPoint?) -> NSScreen {
        let screens = NSScreen.screens

        // Authoritative source: the displayID the user docked onto, persisted
        // in preferences and refreshed every time the panel is dragged. We
        // try this first so a collapsed panel sitting on the right-screen's
        // left edge (where panel.frame.x straddles the boundary with the
        // left screen) doesn't get re-classified to the neighbour on every
        // expand.
        if let stored = storedScreen() {
            return stored
        }

        // Fallback for fresh installs / disconnected displays / pre-displayID
        // upgrade: pick the screen whose frame contains the most of the
        // panel's current frame.
        if let panel, !screens.isEmpty {
            var bestScreen: NSScreen?
            var bestArea: CGFloat = 0
            for screen in screens {
                let overlap = screen.frame.intersection(panel.frame)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > bestArea {
                    bestArea = area
                    bestScreen = screen
                }
            }
            if let bestScreen, bestArea > 0 {
                return bestScreen
            }
        }
        if let point {
            if let containing = screens.first(where: { $0.visibleFrame.contains(point) || $0.frame.contains(point) }) {
                return containing
            }
            if let nearest = screens.min(by: { distance(from: point, to: $0.frame) < distance(from: point, to: $1.frame) }) {
                return nearest
            }
        }
        guard let fallback = NSScreen.main ?? screens.first else {
            preconditionFailure("Floating stats panel requires at least one screen")
        }
        return fallback
    }

    private func storedScreen() -> NSScreen? {
        guard let preferences, preferences.floatingTabDisplayID != 0 else { return nil }
        let target = preferences.floatingTabDisplayID
        return NSScreen.screens.first { $0.displayID == target }
    }

    private func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }
}

extension NSScreen {
    /// CGDirectDisplayID of this screen, when AppKit can resolve one. Stable
    /// across launches for the same physical display so we use it to lock the
    /// floating panel to a specific monitor instead of guessing from frames.
    var displayID: UInt32 {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = deviceDescription[key] as? NSNumber {
            return number.uint32Value
        }
        return 0
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }

    func isApproximatelyEqual(to other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(origin.x - other.origin.x) <= tolerance
            && abs(origin.y - other.origin.y) <= tolerance
            && abs(size.width - other.size.width) <= tolerance
            && abs(size.height - other.size.height) <= tolerance
    }
}
