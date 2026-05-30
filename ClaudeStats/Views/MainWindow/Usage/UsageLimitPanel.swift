import SwiftUI

struct UsageLimitPanel: View {
    let provider: ProviderKind
    let report: UsageLimitReport?
    let isLoading: Bool
    let actionMessage: String?
    let trendEstimates: [String: UsageLimitTrendEstimate]
    let onRefresh: () -> Void
    let claudeBridgeStatus: ClaudeUsageLimitBridgeStatus?
    let onInstallClaudeBridgeAuto: (() -> Void)?
    let onUninstallClaudeBridgeAuto: (() -> Void)?
    let onInstallClaudeBridge: (() -> Void)?
    let onCopyClaudeSettingsSnippet: (() -> Void)?
    let onOpenClaudeSettings: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .mainUsagePanel(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            L10n.format("usage.limit.accessibility.provider_limits",
                        defaultValue: "%@ usage limits",
                        provider.shortName)
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("USAGE LIMITS")
                .font(.sora(13, weight: .semibold))
                .tracking(1.0)
            statusBadge
            Spacer(minLength: 12)
            if let label = updatedLabel {
                Text(label)
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.stxMuted)
            .help(L10n.string("usage.limit.refresh", defaultValue: "Refresh usage limits"))
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let status = report?.status ?? (isLoading ? .waitingForNextResponse : .unsupported)
        HStack(spacing: 5) {
            Circle()
                .fill(tint(for: status))
                .frame(width: 6, height: 6)
            Text(label(for: status))
                .font(.sora(9, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tint(for: status))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint(for: status).opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(tint(for: status).opacity(0.35), lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if let report {
            switch report.status {
            case .fresh:
                if let snapshot = report.snapshot {
                    limitWindows(snapshot.windows)
                    sourceFooter(snapshot: snapshot)
                }
            case .setupRequired where provider == .claude:
                setupRequiredContent(message: report.message)
            case .waitingForNextResponse:
                waitingContent(report: report)
            case .unavailable:
                stateContent(
                    systemImage: "exclamationmark.triangle.fill",
                    title: L10n.string("usage.limit.unavailable_title",
                                       defaultValue: "Usage limits unavailable"),
                    message: report.message,
                    lastCapturedAt: report.lastCapturedAt
                )
            case .setupRequired:
                stateContent(
                    systemImage: "wrench.and.screwdriver.fill",
                    title: L10n.string("usage.limit.setup_required_title",
                                       defaultValue: "Setup required"),
                    message: report.message,
                    lastCapturedAt: report.lastCapturedAt
                )
            case .unsupported:
                EmptyView()
            }
        } else {
            stateContent(
                systemImage: "clock.arrow.circlepath",
                title: isLoading
                    ? L10n.string("usage.limit.checking_title", defaultValue: "Checking usage limits")
                    : L10n.string("usage.limit.not_loaded_title", defaultValue: "Usage limits not loaded"),
                message: nil,
                lastCapturedAt: nil
            )
        }
        if provider == .claude, (onInstallClaudeBridgeAuto != nil || onUninstallClaudeBridgeAuto != nil) {
            StxRule()
            claudeBridgeButtons
        }
        if let actionMessage {
            StxRule()
            Text(actionMessage)
                .font(.sora(11))
                .foregroundStyle(Color.stxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limitWindows(_ windows: [UsageLimitWindow]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 320), spacing: 24, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(windows) { window in
                UsageLimitWindowCard(
                    model: UsageLimitWindowCardModel(
                        window: window,
                        trendEstimate: trendEstimates[window.id],
                        predictsExhaust: UsageLimitStore.predictsExhaust(windowID: window.id)
                    )
                )
                .equatable()
            }
        }
    }

    private func setupRequiredContent(message: String?) -> some View {
        stateContent(
            systemImage: "terminal.fill",
            title: L10n.string("usage.limit.connect_usage_sources",
                               defaultValue: "Connect Claude usage sources"),
            message: message,
            lastCapturedAt: nil
        )
    }

    @ViewBuilder
    private func waitingContent(report: UsageLimitReport) -> some View {
        stateContent(
            systemImage: "clock.arrow.circlepath",
            title: L10n.format("usage.limit.waiting_for_response",
                               defaultValue: "Waiting for the next %@ response",
                               provider.shortName),
            message: report.message,
            lastCapturedAt: report.lastCapturedAt
        )
    }

    @ViewBuilder
    private var claudeBridgeButtons: some View {
        HStack(alignment: .center, spacing: 8) {
            primaryBridgeButton
            advancedBridgeMenu
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var primaryBridgeButton: some View {
        switch claudeBridgeStatus ?? .notInstalled {
        case .installed:
            if let onUninstallClaudeBridgeAuto {
                Button(role: .destructive, action: onUninstallClaudeBridgeAuto) {
                    Label("Disable usage limit tracking", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        case .orphaned:
            if let onInstallClaudeBridgeAuto {
                Button(action: onInstallClaudeBridgeAuto) {
                    Label("Repair usage limit tracking", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        case .notInstalled:
            if let onInstallClaudeBridgeAuto {
                Button(action: onInstallClaudeBridgeAuto) {
                    Label("Enable usage limit tracking", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var advancedBridgeMenu: some View {
        if onInstallClaudeBridge != nil || onCopyClaudeSettingsSnippet != nil || onOpenClaudeSettings != nil {
            Menu {
                if let onInstallClaudeBridge {
                    Button(action: onInstallClaudeBridge) {
                        Label("Install bridge script only", systemImage: "doc.text")
                    }
                }
                if let onCopyClaudeSettingsSnippet {
                    Button(action: onCopyClaudeSettingsSnippet) {
                        Label("Copy settings snippet", systemImage: "doc.on.doc")
                    }
                }
                if let onOpenClaudeSettings {
                    Button(action: onOpenClaudeSettings) {
                        Label("Open Claude settings", systemImage: "arrow.up.right.square")
                    }
                }
            } label: {
                Label("Advanced", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .fixedSize()
        }
    }

    private func stateContent(systemImage: String, title: String, message: String?, lastCapturedAt: Date?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.stxMuted)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(title))
                    .font(.sora(12, weight: .semibold))
                    .foregroundStyle(.primary)
                if let message {
                    Text(LocalizedStringKey(message))
                        .font(.sora(11))
                        .foregroundStyle(Color.stxMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let lastCapturedAt {
                    Text(L10n.format("usage.limit.last_snapshot",
                                     defaultValue: "Last snapshot %@",
                                     Format.relativeDate(lastCapturedAt)))
                        .font(.sora(10))
                        .foregroundStyle(Color.stxMuted)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func sourceFooter(snapshot: UsageLimitSnapshot) -> some View {
        HStack(spacing: 8) {
            Text(snapshot.sourceLabel)
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .lineLimit(1)
            if let planType = snapshot.planType {
                Text(planType)
                    .font(.sora(9, weight: .semibold))
                    .foregroundStyle(Color.stxMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())
            }
            Spacer(minLength: 0)
        }
    }

    private var updatedLabel: String? {
        guard let capturedAt = report?.lastCapturedAt else { return nil }
        return L10n.format("usage.limit.updated",
                           defaultValue: "Updated %@",
                           Format.relativeDate(capturedAt))
    }

    private func label(for status: UsageLimitStatus) -> String {
        switch status {
        case .fresh:
            L10n.string("usage.limit.status.fresh", defaultValue: "FRESH")
        case .setupRequired:
            L10n.string("usage.limit.status.setup", defaultValue: "SETUP")
        case .waitingForNextResponse:
            L10n.string("usage.limit.status.waiting", defaultValue: "WAITING")
        case .unavailable:
            L10n.string("usage.limit.status.unavailable", defaultValue: "UNAVAILABLE")
        case .unsupported:
            L10n.string("usage.limit.status.unsupported", defaultValue: "UNSUPPORTED")
        }
    }

    private func tint(for status: UsageLimitStatus) -> Color {
        switch status {
        case .fresh:
            Color.green
        case .setupRequired:
            Color.blue
        case .waitingForNextResponse:
            Color.orange
        case .unavailable:
            Color.red
        case .unsupported:
            Color.stxMuted
        }
    }
}

struct UsageLimitSegmentLayout: Equatable, Sendable {
    static let defaultSegmentCount = 28

    let usedPercent: Double
    let segmentCount: Int

    init(usedPercent: Double, segmentCount: Int = Self.defaultSegmentCount) {
        self.usedPercent = usedPercent
        self.segmentCount = max(1, segmentCount)
    }

    var clampedUsedPercent: Double {
        min(100, max(0, usedPercent))
    }

    var usedSegmentCount: Int {
        guard clampedUsedPercent > 0 else { return 0 }
        let rawCount = (clampedUsedPercent / 100) * Double(segmentCount)
        return min(segmentCount, max(1, Int(rawCount.rounded(.up))))
    }

    var remainingSegmentCount: Int {
        segmentCount - usedSegmentCount
    }
}

struct UsageLimitWindowCardModel: Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let resetText: String
    let remainingText: String
    let usedText: String
    let accessibilityValue: String
    let segmentLayout: UsageLimitSegmentLayout
    let tintLevel: UsageLimitTintLevel
    let exhaust: ExhaustPresentation?
    /// Whether this window has exhaust prediction at all. False for windows
    /// like 7d where the burn-rate extrapolation isn't useful — those cards
    /// hide the hint entirely rather than showing a stuck "Sampling…".
    let predictsExhaust: Bool
    /// True when the window's `resets_at` has already passed but Claude Code
    /// hasn't sent us the new-window snapshot yet — the cached used_percent
    /// is referring to a closed quota window. We dim the numbers so it's
    /// obvious the value is no longer authoritative.
    let isWaitingForReset: Bool

    init(window: UsageLimitWindow, trendEstimate: UsageLimitTrendEstimate? = nil, predictsExhaust: Bool = true, now: Date = .now) {
        let remainingText = Format.percentPoints(window.remainingPercent)
        let usedText = Format.percentPoints(window.clampedUsedPercent)
        let waitingForReset = window.resetAt.map { $0 <= now } ?? false
        let resetText: String
        if waitingForReset {
            resetText = L10n.string(
                "usage.limit.reset_pending",
                defaultValue: "Reset complete · waiting for next response"
            )
        } else if let resetAt = window.resetAt {
            resetText = L10n.format("usage.limit.resets", defaultValue: "Resets %@", Format.relativeDate(resetAt))
        } else {
            resetText = L10n.string("usage.limit.reset_unknown", defaultValue: "Reset unknown")
        }

        self.id = window.id
        self.label = window.label
        self.resetText = resetText
        self.remainingText = remainingText
        self.usedText = L10n.format("usage.limit.used_value", defaultValue: "%@ used", usedText)
        self.accessibilityValue = L10n.format("usage.limit.window_accessibility",
                                              defaultValue: "%@ remaining, %@ used, %@",
                                              remainingText,
                                              usedText,
                                              resetText)
        self.segmentLayout = UsageLimitSegmentLayout(usedPercent: window.clampedUsedPercent)
        self.tintLevel = UsageLimitTintLevel(remainingPercent: window.remainingPercent)
        self.isWaitingForReset = waitingForReset
        self.predictsExhaust = predictsExhaust
        // No prediction makes sense for a closed window — its slope refers to
        // an already-ended quota period.
        self.exhaust = (predictsExhaust && !waitingForReset)
            ? trendEstimate.map { ExhaustPresentation(estimate: $0, window: window) }
            : nil
    }
}

/// Colored "burn-rate" hint shown beneath the segment strip. Matches the
/// `calc_exhaust_mins` traffic-light logic from the user's statusline.sh —
/// safe when extrapolation lasts past the reset, warning when it lands in
/// the last 30% of the window, critical when it runs out far short.
struct ExhaustPresentation: Equatable, Sendable {
    enum Severity: Sendable, Equatable {
        case safe
        case warning
        case danger
        case critical
        case immediate
    }

    let label: String
    let severity: Severity

    init(estimate: UsageLimitTrendEstimate, window: UsageLimitWindow) {
        let minutes = estimate.minutesUntilExhaust
        let formatted = Self.format(minutes: minutes)
        if minutes <= 0 {
            self.label = L10n.string("usage.limit.exhaust.now", defaultValue: "Burning out now")
            self.severity = .immediate
            return
        }
        guard let resetAt = window.resetAt else {
            self.label = L10n.format("usage.limit.exhaust.estimate", defaultValue: "~%@ until full", formatted)
            self.severity = .warning
            return
        }
        let remainingMinutes = max(1, Int(resetAt.timeIntervalSinceNow / 60))
        let severity: Severity
        if minutes >= remainingMinutes {
            severity = .safe  // will last past reset
        } else if minutes >= remainingMinutes * 70 / 100 {
            severity = .warning
        } else if minutes >= remainingMinutes * 30 / 100 {
            severity = .danger
        } else {
            severity = .critical
        }
        self.severity = severity
        self.label = L10n.format("usage.limit.exhaust.estimate", defaultValue: "~%@ until full", formatted)
    }

    private static func format(minutes: Int) -> String {
        if minutes <= 0 { return "0m" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    var color: Color {
        switch severity {
        case .safe: Color.green
        case .warning: Color.orange
        case .danger: Color.red
        case .critical: Color.red
        case .immediate: Color.red
        }
    }

    var icon: String {
        switch severity {
        case .safe: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .danger: "bolt.fill"
        case .critical: "bolt.trianglebadge.exclamationmark"
        case .immediate: "exclamationmark.octagon.fill"
        }
    }
}

enum UsageLimitTintLevel: Equatable, Sendable {
    case healthy
    case warning
    case critical

    init(remainingPercent: Double) {
        switch remainingPercent {
        case let remaining where remaining > 50:
            self = .healthy
        case 20...50:
            self = .warning
        default:
            self = .critical
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            Color.green
        case .warning:
            Color.orange
        case .critical:
            Color.red
        }
    }
}

struct UsageLimitWindowCard: View, Equatable {
    let model: UsageLimitWindowCardModel
    /// Compact mode shrinks fonts, the segment bar, and overall padding so
    /// the same visual language fits inside the 320pt floating tab.
    var compact: Bool = false

    @ViewBuilder
    fileprivate func exhaustHint(model: UsageLimitWindowCardModel) -> some View {
        if !model.predictsExhaust || model.isWaitingForReset {
            EmptyView()
        } else if let exhaust = model.exhaust {
            Label {
                Text(LocalizedStringKey(exhaust.label))
                    .font(.sora(10, weight: .semibold))
            } icon: {
                Image(systemName: exhaust.icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(exhaust.color)
            .help(L10n.string(
                "usage.limit.exhaust.help",
                defaultValue: "Projected from your last 30 minutes of burn rate. Updates as new samples arrive."
            ))
        } else {
            Label {
                Text(L10n.string("usage.limit.exhaust.sampling", defaultValue: "Sampling…"))
                    .font(.sora(10, weight: .medium))
            } icon: {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Color.stxMuted)
            .help(L10n.string(
                "usage.limit.exhaust.sampling.help",
                defaultValue: "Collecting burn-rate samples. Predicted exhaust time will appear once we have 10+ minutes of data."
            ))
        }
    }

    private var bigNumberFontSize: CGFloat { compact ? 17 : 24 }
    private var sectionSpacing: CGFloat { compact ? 6 : 9 }
    private var verticalPadding: CGFloat { compact ? 0 : 4 }
    private var stripHeight: CGFloat { compact ? 18 : 34 }
    private var stripSegmentCount: Int { compact ? 18 : 28 }

    var body: some View {
        VStack(alignment: .leading, spacing: sectionSpacing) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.label)
                    .font(.sora(10, weight: .semibold))
                    .foregroundStyle(Color.stxMuted)
                Spacer(minLength: 8)
                Text(model.resetText)
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(model.remainingText)
                    .font(.sora(bigNumberFontSize, weight: .semibold).monospacedDigit())
                    .foregroundStyle(model.isWaitingForReset ? Color.stxMuted : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .stxNumericValueTransition(value: model.remainingText)
                Text("left")
                    .font(.sora(11, weight: .medium))
                    .foregroundStyle(Color.stxMuted)
                Spacer(minLength: 8)
                Text(model.usedText)
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }
            .opacity(model.isWaitingForReset ? 0.55 : 1)

            UsageLimitSegmentStrip(
                layout: UsageLimitSegmentLayout(
                    usedPercent: model.segmentLayout.usedPercent,
                    segmentCount: stripSegmentCount
                ),
                remainingTint: model.tintLevel.color,
                segmentHeight: stripHeight
            )

            HStack(spacing: 10) {
                if !compact {
                    UsageLimitSegmentLegendItem(label: L10n.string("usage.limit.left", defaultValue: "Left"), tint: model.tintLevel.color, style: .solid)
                    UsageLimitSegmentLegendItem(label: L10n.string("usage.limit.used", defaultValue: "Used"), tint: Color.primary.opacity(0.34), style: .hatched)
                }
                Spacer(minLength: 0)
                exhaustHint(model: model)
            }
        }
        .padding(.vertical, verticalPadding)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("usage.limit.window_label",
                                        defaultValue: "%@ usage limit",
                                        model.label))
        .accessibilityValue(model.accessibilityValue)
    }
}

struct UsageLimitSegmentStrip: View {
    let layout: UsageLimitSegmentLayout
    let remainingTint: Color
    var segmentHeight: CGFloat = 34

    private let segmentSpacing: CGFloat = 4
    private let segmentCornerRadius: CGFloat = 1.5
    private let usedBaseTint = Color.primary.opacity(0.12)
    private let usedStripeTint = Color.primary.opacity(0.34)

    var body: some View {
        Canvas { context, size in
            let totalSpacing = CGFloat(layout.segmentCount - 1) * segmentSpacing
            let segmentWidth = (size.width - totalSpacing) / CGFloat(layout.segmentCount)
            guard segmentWidth > 0, size.height > 0 else { return }

            for index in 0..<layout.segmentCount {
                let origin = CGPoint(x: CGFloat(index) * (segmentWidth + segmentSpacing), y: 0)
                let rect = CGRect(origin: origin, size: CGSize(width: segmentWidth, height: size.height))
                let cornerRadius = min(segmentCornerRadius, segmentWidth / 2, size.height / 2)
                let path = Path(roundedRect: rect, cornerRadius: cornerRadius)

                if index < layout.remainingSegmentCount {
                    context.fill(path, with: .color(remainingTint))
                } else {
                    context.fill(path, with: .color(usedBaseTint))
                    drawUsedStripes(in: rect, clippedTo: path, context: context)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: segmentHeight)
        .accessibilityHidden(true)
    }

    private func drawUsedStripes(in rect: CGRect, clippedTo clippingPath: Path, context: GraphicsContext) {
        var stripeContext = context
        stripeContext.clip(to: clippingPath)

        var stripePath = Path()
        var startX = rect.minX - rect.height
        while startX < rect.maxX {
            stripePath.move(to: CGPoint(x: startX, y: rect.maxY))
            stripePath.addLine(to: CGPoint(x: startX + rect.height, y: rect.minY))
            startX += 6
        }

        stripeContext.stroke(
            stripePath,
            with: .color(usedStripeTint),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )
    }
}

private struct UsageLimitSegmentLegendItem: View {
    enum Style {
        case solid
        case hatched
    }

    let label: String
    let tint: Color
    let style: Style

    var body: some View {
        HStack(spacing: 5) {
            Group {
                switch style {
                case .solid:
                    Rectangle()
                        .fill(tint)
                case .hatched:
                    UsageLimitHatchedSwatch()
                }
            }
            .frame(width: 8, height: 8)
            Text(label)
                .font(.sora(9))
                .foregroundStyle(Color.stxMuted)
        }
        .accessibilityHidden(true)
    }
}

private struct UsageLimitHatchedSwatch: View {
    private let baseTint = Color.primary.opacity(0.12)
    private let stripeTint = Color.primary.opacity(0.34)

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let path = Path(roundedRect: rect, cornerRadius: 1.5)
            context.fill(path, with: .color(baseTint))

            var stripeContext = context
            stripeContext.clip(to: path)

            var stripes = Path()
            var startX = rect.minX - rect.height
            while startX < rect.maxX {
                stripes.move(to: CGPoint(x: startX, y: rect.maxY))
                stripes.addLine(to: CGPoint(x: startX + rect.height, y: rect.minY))
                startX += 5
            }

            stripeContext.stroke(stripes, with: .color(stripeTint), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        }
    }
}

#if DEBUG
#Preview {
    UsageLimitPanel(
        provider: .claude,
        report: .fresh(
            provider: .claude,
            snapshot: UsageLimitSnapshot(
                provider: .claude,
                windows: [
                    UsageLimitWindow(id: "primary", label: "5h", usedPercent: 38, resetAt: Date().addingTimeInterval(2_400), windowMinutes: 300),
                    UsageLimitWindow(id: "secondary", label: "7d", usedPercent: 12, resetAt: Date().addingTimeInterval(400_000), windowMinutes: 10_080),
                ],
                capturedAt: Date().addingTimeInterval(-120),
                sourceLabel: "Claude session",
                sourcePath: nil,
                planType: "pro",
                limitID: "claude"
            )
        ),
        isLoading: false,
        actionMessage: nil,
        trendEstimates: [:],
        onRefresh: {},
        claudeBridgeStatus: .notInstalled,
        onInstallClaudeBridgeAuto: nil,
        onUninstallClaudeBridgeAuto: nil,
        onInstallClaudeBridge: nil,
        onCopyClaudeSettingsSnippet: nil,
        onOpenClaudeSettings: nil
    )
    .padding(24)
    .frame(width: 760)
    .background(Color.stxBackground)
}
#endif
