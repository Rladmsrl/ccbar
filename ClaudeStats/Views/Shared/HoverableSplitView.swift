import AppKit
import SwiftUI

/// A reusable SwiftUI wrapper around `NSSplitView` with an accent pill on the
/// divider. SwiftUI owns the pane content; AppKit owns native split dragging,
/// cursor rects, and the transient hover affordance.
struct HoverableSplitView<Primary: View, Secondary: View>: NSViewRepresentable {
    let axis: HoverableSplitAxis
    let primaryFraction: CGFloat
    let configuration: HoverableSplitViewConfiguration
    private let primary: Primary
    private let secondary: Secondary

    init(
        axis: HoverableSplitAxis,
        primaryFraction: CGFloat = 0.5,
        configuration: HoverableSplitViewConfiguration = .default,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.axis = axis
        self.primaryFraction = primaryFraction
        self.configuration = configuration
        self.primary = primary()
        self.secondary = secondary()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(configuration: configuration)
    }

    func makeNSView(context: Context) -> HoverablePillSplitView {
        let splitView = HoverablePillSplitView(
            axis: axis,
            primaryFraction: primaryFraction,
            configuration: configuration
        )
        splitView.delegate = context.coordinator
        context.coordinator.install(in: splitView, primary: primary, secondary: secondary)
        return splitView
    }

    func updateNSView(_ splitView: HoverablePillSplitView, context: Context) {
        context.coordinator.configuration = configuration
        splitView.updateConfiguration(
            axis: axis,
            primaryFraction: primaryFraction,
            configuration: configuration
        )
        splitView.delegate = context.coordinator
        context.coordinator.update(primary: primary, secondary: secondary)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var configuration: HoverableSplitViewConfiguration
        private var primaryHostingView: NSHostingView<AnyView>?
        private var secondaryHostingView: NSHostingView<AnyView>?

        init(configuration: HoverableSplitViewConfiguration) {
            self.configuration = configuration
        }

        func install(in splitView: HoverablePillSplitView, primary: Primary, secondary: Secondary) {
            if primaryHostingView == nil {
                let primaryView = hostingView(for: AnyView(primary))
                let secondaryView = hostingView(for: AnyView(secondary))
                splitView.addSubview(primaryView)
                splitView.addSubview(secondaryView)
                primaryHostingView = primaryView
                secondaryHostingView = secondaryView
            }
            update(primary: primary, secondary: secondary)
        }

        func update(primary: Primary, secondary: Secondary) {
            primaryHostingView?.rootView = AnyView(primary)
            secondaryHostingView?.rootView = AnyView(secondary)
        }

        func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
            false
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard let range = configuration.dividerPositionRange(for: length) else { return proposedMinimumPosition }
            return max(proposedMinimumPosition, range.lowerBound)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            let length = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard let range = configuration.dividerPositionRange(for: length) else { return proposedMaximumPosition }
            return min(proposedMaximumPosition, range.upperBound)
        }

        func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
            guard let splitView = splitView as? HoverablePillSplitView else { return .zero }
            return splitView.additionalEffectiveDividerRect(at: dividerIndex)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? HoverablePillSplitView else { return }
            splitView.refreshDividerAfterPaneResize()
        }

        private func hostingView(for rootView: AnyView) -> NSHostingView<AnyView> {
            let view = NSHostingView(rootView: rootView)
            view.autoresizingMask = [.width, .height]
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentHuggingPriority(.defaultLow, for: .vertical)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            return view
        }
    }
}

enum HoverableSplitAxis: Equatable, Sendable {
    /// A left/right split with a vertical divider and a vertical pill.
    case vertical
    /// A top/bottom split with a horizontal divider and a horizontal pill.
    case horizontal

    var splitViewIsVertical: Bool {
        self == .vertical
    }

    var resizeCursor: NSCursor {
        switch self {
        case .vertical:
            .resizeLeftRight
        case .horizontal:
            .resizeUpDown
        }
    }

    func expandedHoverRect(_ rect: NSRect, by amount: CGFloat) -> NSRect {
        switch self {
        case .vertical:
            rect.insetBy(dx: -amount, dy: 0)
        case .horizontal:
            rect.insetBy(dx: 0, dy: -amount)
        }
    }
}

struct HoverableSplitViewConfiguration: Equatable, @unchecked Sendable {
    var minimumPaneLength: CGFloat
    var primaryMinimumPaneLength: CGFloat?
    var primaryMaximumPaneLength: CGFloat?
    var secondaryMinimumPaneLength: CGFloat?
    var secondaryMaximumPaneLength: CGFloat?
    var hoverExpansion: CGFloat
    var minimumPillInset: CGFloat
    var verticalPillSize: CGSize
    var horizontalPillSize: CGSize
    var pillColor: NSColor
    var fadeDuration: CFTimeInterval
    var dragUpdateInterval: TimeInterval

    static let `default` = HoverableSplitViewConfiguration()

    init(
        minimumPaneLength: CGFloat = 120,
        primaryMinimumPaneLength: CGFloat? = nil,
        primaryMaximumPaneLength: CGFloat? = nil,
        secondaryMinimumPaneLength: CGFloat? = nil,
        secondaryMaximumPaneLength: CGFloat? = nil,
        hoverExpansion: CGFloat = 5,
        minimumPillInset: CGFloat = 12,
        verticalPillSize: CGSize = CGSize(width: 3, height: 52),
        horizontalPillSize: CGSize = CGSize(width: 52, height: 3),
        pillColor: NSColor = NSColor(srgbRed: 0.94, green: 0.42, blue: 0.12, alpha: 1),
        fadeDuration: CFTimeInterval = 0.16,
        dragUpdateInterval: TimeInterval = 1.0 / 120.0
    ) {
        self.minimumPaneLength = minimumPaneLength
        self.primaryMinimumPaneLength = primaryMinimumPaneLength
        self.primaryMaximumPaneLength = primaryMaximumPaneLength
        self.secondaryMinimumPaneLength = secondaryMinimumPaneLength
        self.secondaryMaximumPaneLength = secondaryMaximumPaneLength
        self.hoverExpansion = hoverExpansion
        self.minimumPillInset = minimumPillInset
        self.verticalPillSize = verticalPillSize
        self.horizontalPillSize = horizontalPillSize
        self.pillColor = pillColor
        self.fadeDuration = fadeDuration
        self.dragUpdateInterval = dragUpdateInterval
    }

    func pillSize(for axis: HoverableSplitAxis) -> CGSize {
        switch axis {
        case .vertical:
            verticalPillSize
        case .horizontal:
            horizontalPillSize
        }
    }

    func dividerPositionRange(for length: CGFloat) -> ClosedRange<CGFloat>? {
        guard length.isFinite, length > 0 else { return nil }

        let primaryMinimum = sanitizedPaneLength(primaryMinimumPaneLength ?? minimumPaneLength) ?? 0
        let secondaryMinimum = sanitizedPaneLength(secondaryMinimumPaneLength ?? minimumPaneLength) ?? 0
        let combinedMinimum = primaryMinimum + secondaryMinimum
        let minimumScale = combinedMinimum > length && combinedMinimum > 0
            ? length / combinedMinimum
            : 1

        let effectivePrimaryMinimum = primaryMinimum * minimumScale
        let effectiveSecondaryMinimum = secondaryMinimum * minimumScale
        var minimumPosition = effectivePrimaryMinimum
        var maximumPosition = length - effectiveSecondaryMinimum

        if let primaryMaximum = sanitizedPaneLength(primaryMaximumPaneLength) {
            maximumPosition = min(maximumPosition, primaryMaximum)
        }
        if let secondaryMaximum = sanitizedPaneLength(secondaryMaximumPaneLength) {
            minimumPosition = max(minimumPosition, length - secondaryMaximum)
        }

        minimumPosition = clampedPosition(minimumPosition, length: length)
        maximumPosition = clampedPosition(maximumPosition, length: length)

        guard maximumPosition >= minimumPosition else {
            let fallbackPosition = clampedPosition((minimumPosition + maximumPosition) / 2, length: length)
            return fallbackPosition...fallbackPosition
        }

        return minimumPosition...maximumPosition
    }

    private func sanitizedPaneLength(_ value: CGFloat?) -> CGFloat? {
        guard let value, value.isFinite else { return nil }
        return max(0, value)
    }

    private func clampedPosition(_ value: CGFloat, length: CGFloat) -> CGFloat {
        min(max(value, 0), length)
    }

    static func == (lhs: HoverableSplitViewConfiguration, rhs: HoverableSplitViewConfiguration) -> Bool {
        lhs.minimumPaneLength == rhs.minimumPaneLength
            && lhs.primaryMinimumPaneLength == rhs.primaryMinimumPaneLength
            && lhs.primaryMaximumPaneLength == rhs.primaryMaximumPaneLength
            && lhs.secondaryMinimumPaneLength == rhs.secondaryMinimumPaneLength
            && lhs.secondaryMaximumPaneLength == rhs.secondaryMaximumPaneLength
            && lhs.hoverExpansion == rhs.hoverExpansion
            && lhs.minimumPillInset == rhs.minimumPillInset
            && lhs.verticalPillSize == rhs.verticalPillSize
            && lhs.horizontalPillSize == rhs.horizontalPillSize
            && lhs.pillColor.isEqual(rhs.pillColor)
            && lhs.fadeDuration == rhs.fadeDuration
            && lhs.dragUpdateInterval == rhs.dragUpdateInterval
    }
}

@MainActor
final class HoverablePillSplitView: NSSplitView {
    private static weak var activeSplitView: HoverablePillSplitView?

    private var axis: HoverableSplitAxis
    private var primaryFraction: CGFloat
    private var configuration: HoverableSplitViewConfiguration
    private let dividerLineLayer = CALayer()
    private let pillLayer = CALayer()
    private var pillTrackingArea: NSTrackingArea?
    private var hoveredDividerIndex: Int?
    private var activeDividerIndex: Int?
    private var localDragMonitor: Any?
    private var dragUpdateTimer: Timer?
    private var hasAppliedInitialSplit = false

    override var dividerThickness: CGFloat {
        // AppKit's built-in 1px divider can leave stale strokes while a
        // layer-backed split view is dragged. The panes should abut; our custom
        // layer below owns the visible divider and the delegate owns hit testing.
        0
    }

    init(
        axis: HoverableSplitAxis,
        primaryFraction: CGFloat,
        configuration: HoverableSplitViewConfiguration
    ) {
        self.axis = axis
        self.primaryFraction = primaryFraction
        self.configuration = configuration
        super.init(frame: .zero)
        isVertical = axis.splitViewIsVertical
        dividerStyle = .thin
        autoresizesSubviews = true
        wantsLayer = true
        setupDividerLineLayer()
        setupPillLayer()
    }

    required init?(coder: NSCoder) {
        axis = .vertical
        primaryFraction = 0.5
        configuration = .default
        super.init(coder: coder)
        isVertical = axis.splitViewIsVertical
        dividerStyle = .thin
        autoresizesSubviews = true
        wantsLayer = true
        setupDividerLineLayer()
        setupPillLayer()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            stopDragUpdateTimer()
            removeLocalDragMonitor()
            hidePill(animated: false, force: true)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateDividerLineLayerAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pillTrackingArea {
            removeTrackingArea(pillTrackingArea)
        }

        let options: NSTrackingArea.Options = [
            .activeInKeyWindow,
            .enabledDuringMouseDrag,
            .inVisibleRect,
            .mouseEnteredAndExited,
            .mouseMoved,
        ]
        let trackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
        pillTrackingArea = trackingArea
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for index in 0..<dividerCount {
            guard var cursorRect = dividerRect(at: index) else { continue }
            cursorRect = axis.expandedHoverRect(cursorRect, by: configuration.hoverExpansion)
            addCursorRect(cursorRect, cursor: axis.resizeCursor)
        }
    }

    override func drawDivider(in rect: NSRect) {
        // A layer-backed NSSplitView can leave stale native divider strokes while
        // the window is being resized. The explicit divider layer below moves
        // with the panes and avoids drawing old divider positions.
    }

    override func layout() {
        applyInitialSplitIfNeeded()
        super.layout()
        clampDividerPositionIfNeeded()
        refreshDividerVisuals()
        attachPillLayerIfNeeded()
        refreshVisiblePill()
    }

    override func mouseEntered(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        if activeDividerIndex == nil {
            hidePill()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateDrag(with: event)
        super.mouseDragged(with: event)
        refreshDividerVisuals()
    }

    override func mouseUp(with event: NSEvent) {
        updateDrag(with: event)
        super.mouseUp(with: event)
        refreshDividerVisuals()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let dividerIndex = hoveredDivider(at: point) else {
            hidePill()
            super.mouseDown(with: event)
            return
        }

        activeDividerIndex = dividerIndex
        showPill(for: dividerIndex, at: point)
        installLocalDragMonitor()
        startDragUpdateTimer()

        super.mouseDown(with: event)

        finishDividerDrag(for: dividerIndex)
    }

    func updateConfiguration(
        axis newAxis: HoverableSplitAxis,
        primaryFraction newPrimaryFraction: CGFloat,
        configuration newConfiguration: HoverableSplitViewConfiguration
    ) {
        let clampedFraction = clamp(newPrimaryFraction, min: 0.1, max: 0.9)
        let axisChanged = axis != newAxis
        let fractionChanged = abs(primaryFraction - clampedFraction) > 0.001
        let configurationChanged = configuration != newConfiguration
        guard axisChanged || fractionChanged || configurationChanged else { return }

        if axisChanged {
            axis = newAxis
            isVertical = newAxis.splitViewIsVertical
            hasAppliedInitialSplit = false
            hidePill(animated: false, force: true)
        }
        if fractionChanged {
            primaryFraction = clampedFraction
            hasAppliedInitialSplit = false
        }
        configuration = newConfiguration
        if axisChanged || configurationChanged {
            updateDividerLineLayerAppearance()
            updatePillLayerAppearance()
        }
        needsLayout = true
        window?.invalidateCursorRects(for: self)
    }

    func additionalEffectiveDividerRect(at index: Int) -> NSRect {
        guard let dividerRect = dividerRect(at: index) else { return .zero }
        return axis.expandedHoverRect(dividerRect, by: configuration.hoverExpansion)
    }

    func refreshDividerAfterPaneResize() {
        refreshDividerVisuals()
        refreshVisiblePill()
    }

    private var dividerCount: Int {
        max(subviews.count - 1, 0)
    }

    private func setupDividerLineLayer() {
        dividerLineLayer.opacity = 1
        dividerLineLayer.zPosition = 998
        updateDividerLineLayerAppearance()
        attachDividerLineLayerIfNeeded()
    }

    private func updateDividerLineLayerAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark
            ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.14)
            : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.14)
        dividerLineLayer.backgroundColor = color.cgColor
    }

    private func attachDividerLineLayerIfNeeded() {
        guard let layer, dividerLineLayer.superlayer !== layer else { return }
        dividerLineLayer.removeFromSuperlayer()
        layer.addSublayer(dividerLineLayer)
    }

    private func layoutDividerLine() {
        guard let dividerRect = dividerRect(at: 0) else {
            invalidateDividerLineFrame(dividerLineLayer.frame)
            dividerLineLayer.frame = .zero
            return
        }

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / max(scale, 1)
        let frame: NSRect
        switch axis {
        case .vertical:
            frame = NSRect(
                x: dividerRect.midX - thickness / 2,
                y: 0,
                width: thickness,
                height: bounds.height
            )
        case .horizontal:
            frame = NSRect(
                x: 0,
                y: dividerRect.midY - thickness / 2,
                width: bounds.width,
                height: thickness
            )
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dividerLineLayer.frame != frame {
            invalidateDividerLineFrame(dividerLineLayer.frame.union(frame))
        }
        dividerLineLayer.frame = frame
        CATransaction.commit()
    }

    private func refreshDividerVisuals() {
        attachDividerLineLayerIfNeeded()
        layoutDividerLine()
    }

    private func invalidateDividerLineFrame(_ frame: CGRect) {
        guard !frame.isNull, !frame.isEmpty else { return }
        let invalidationRect = NSRect(
            x: floor(frame.minX) - 2,
            y: floor(frame.minY) - 2,
            width: ceil(frame.width) + 4,
            height: ceil(frame.height) + 4
        )
        setNeedsDisplay(invalidationRect)
        layer?.setNeedsDisplay(invalidationRect)
    }

    private func setupPillLayer() {
        pillLayer.opacity = 0
        pillLayer.masksToBounds = false
        pillLayer.zPosition = 999
        updatePillLayerAppearance()
        attachPillLayerIfNeeded()
    }

    private func updatePillLayerAppearance() {
        pillLayer.backgroundColor = configuration.pillColor.cgColor
        pillLayer.shadowColor = configuration.pillColor.withAlphaComponent(0.4).cgColor
        pillLayer.shadowOpacity = 1
        pillLayer.shadowRadius = 6
        pillLayer.shadowOffset = .zero
        let size = configuration.pillSize(for: axis)
        pillLayer.cornerRadius = min(size.width, size.height) / 2
    }

    private func attachPillLayerIfNeeded() {
        guard let layer, pillLayer.superlayer !== layer else { return }
        pillLayer.removeFromSuperlayer()
        pillLayer.opacity = 0
        layer.addSublayer(pillLayer)
    }

    private func updateHover(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let activeDividerIndex {
            showPill(for: activeDividerIndex, at: point)
            return
        }
        guard let dividerIndex = hoveredDivider(at: point) else {
            hidePill()
            return
        }
        showPill(for: dividerIndex, at: point)
    }

    private func updateDrag(with event: NSEvent) {
        guard let activeDividerIndex else { return }
        refreshDividerVisuals()
        showPill(for: activeDividerIndex, at: convert(event.locationInWindow, from: nil))
    }

    private func updateDragFromCurrentMouseLocation() {
        guard let activeDividerIndex,
              let window else { return }
        refreshDividerVisuals()
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        showPill(for: activeDividerIndex, at: point)
    }

    private func hoveredDivider(at point: NSPoint) -> Int? {
        guard dividerCount > 0 else { return nil }

        for index in 0..<dividerCount {
            guard var hoverRect = dividerRect(at: index) else { continue }
            hoverRect = axis.expandedHoverRect(hoverRect, by: configuration.hoverExpansion)
            if hoverRect.contains(point) {
                return index
            }
        }
        return nil
    }

    private func showPill(for dividerIndex: Int, at point: NSPoint) {
        if Self.activeSplitView !== self {
            Self.activeSplitView?.hidePill(animated: false, force: true)
            Self.activeSplitView = self
        }

        hoveredDividerIndex = dividerIndex
        layoutPill(for: dividerIndex, at: point)
        setPillVisible(true)
    }

    private func layoutPill(for dividerIndex: Int, at point: NSPoint) {
        guard let dividerRect = dividerRect(at: dividerIndex) else { return }
        let size = configuration.pillSize(for: axis)
        let inset = configuration.minimumPillInset
        let maxX = max(inset, bounds.width - size.width - inset)
        let maxY = max(inset, bounds.height - size.height - inset)

        let frame: NSRect
        switch axis {
        case .vertical:
            frame = NSRect(
                x: dividerRect.midX - size.width / 2,
                y: clamp(point.y - size.height / 2, min: inset, max: maxY),
                width: size.width,
                height: size.height
            )
        case .horizontal:
            frame = NSRect(
                x: clamp(point.x - size.width / 2, min: inset, max: maxX),
                y: dividerRect.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pillLayer.frame = frame
        CATransaction.commit()
    }

    private func dividerRect(at index: Int) -> NSRect? {
        guard index >= 0,
              index + 1 < subviews.count else {
            return nil
        }

        let firstPane = subviews[index]
        let secondPane = subviews[index + 1]
        let thickness = max(dividerThickness, 1)

        switch axis {
        case .vertical:
            let center = dividerCenter(
                firstMin: firstPane.frame.minX,
                firstMax: firstPane.frame.maxX,
                secondMin: secondPane.frame.minX,
                secondMax: secondPane.frame.maxX
            )
            return NSRect(x: center - thickness / 2, y: 0, width: thickness, height: bounds.height)
        case .horizontal:
            let center = dividerCenter(
                firstMin: firstPane.frame.minY,
                firstMax: firstPane.frame.maxY,
                secondMin: secondPane.frame.minY,
                secondMax: secondPane.frame.maxY
            )
            return NSRect(x: 0, y: center - thickness / 2, width: bounds.width, height: thickness)
        }
    }

    private func dividerCenter(firstMin: CGFloat, firstMax: CGFloat, secondMin: CGFloat, secondMax: CGFloat) -> CGFloat {
        if firstMax <= secondMin {
            return (firstMax + secondMin) / 2
        }
        if secondMax <= firstMin {
            return (secondMax + firstMin) / 2
        }
        return (firstMax + secondMin) / 2
    }

    private func refreshVisiblePill() {
        guard Self.activeSplitView === self,
              let hoveredDividerIndex,
              let window else { return }
        layoutPill(for: hoveredDividerIndex, at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func hidePill(animated: Bool = true, force: Bool = false) {
        if Self.activeSplitView === self {
            Self.activeSplitView = nil
        }
        hoveredDividerIndex = nil
        if force {
            activeDividerIndex = nil
            stopDragUpdateTimer()
            removeLocalDragMonitor()
        }
        if activeDividerIndex == nil {
            setPillVisible(false, animated: animated)
        }
    }

    private func setPillVisible(_ visible: Bool, animated: Bool = true) {
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(configuration.fadeDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: visible ? .easeOut : .easeIn))
        } else {
            CATransaction.setDisableActions(true)
        }
        pillLayer.opacity = visible ? 1 : 0
        CATransaction.commit()
    }

    private func startDragUpdateTimer() {
        stopDragUpdateTimer()
        let timer = Timer(timeInterval: configuration.dragUpdateInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDragFromCurrentMouseLocation()
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        dragUpdateTimer = timer
    }

    private func stopDragUpdateTimer() {
        dragUpdateTimer?.invalidate()
        dragUpdateTimer = nil
    }

    private func installLocalDragMonitor() {
        removeLocalDragMonitor()
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.updateDrag(with: event)
            }
            return event
        }
    }

    private func removeLocalDragMonitor() {
        if let localDragMonitor {
            NSEvent.removeMonitor(localDragMonitor)
            self.localDragMonitor = nil
        }
    }

    private func finishDividerDrag(for dividerIndex: Int) {
        updateDragFromCurrentMouseLocation()
        stopDragUpdateTimer()
        removeLocalDragMonitor()
        refreshDividerVisuals()
        window?.invalidateCursorRects(for: self)
        activeDividerIndex = nil

        if let window {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if hoveredDivider(at: point) == dividerIndex {
                showPill(for: dividerIndex, at: point)
                return
            }
        }
        hidePill()
    }

    private func applyInitialSplitIfNeeded() {
        guard !hasAppliedInitialSplit,
              subviews.count == 2 else { return }

        let length = axis == .vertical ? bounds.width : bounds.height
        guard let range = configuration.dividerPositionRange(for: length) else { return }

        let position = clamp(length * primaryFraction, min: range.lowerBound, max: range.upperBound)
        setPosition(position, ofDividerAt: 0)
        hasAppliedInitialSplit = true
        needsDisplay = true
        subviews.forEach { $0.needsLayout = true }
        window?.invalidateCursorRects(for: self)
    }

    private func clampDividerPositionIfNeeded() {
        guard hasAppliedInitialSplit,
              subviews.count == 2 else { return }

        let length = axis == .vertical ? bounds.width : bounds.height
        guard let range = configuration.dividerPositionRange(for: length) else { return }

        let primaryPane = subviews[0]
        let currentPosition = axis == .vertical ? primaryPane.frame.maxX : primaryPane.frame.maxY
        let clampedPosition = clamp(currentPosition, min: range.lowerBound, max: range.upperBound)
        guard abs(currentPosition - clampedPosition) > 0.5 else { return }

        setPosition(clampedPosition, ofDividerAt: 0)
        needsDisplay = true
        subviews.forEach { $0.needsLayout = true }
        window?.invalidateCursorRects(for: self)
    }

    private func clamp(_ value: CGFloat, min minimum: CGFloat, max maximum: CGFloat) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return Swift.min(Swift.max(value, minimum), maximum)
    }
}
