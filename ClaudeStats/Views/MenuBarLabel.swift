import SwiftUI

/// The status-item content: a compact horizontal row of the components the
/// user enabled in Settings ▸ Menu bar, separated by middle dots.
struct MenuBarLabel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let segments = enabledSegments
        // The status-item label is rendered into an `NSStatusItem.button`'s
        // attributedTitle — `MenuBarExtra` flattens its content and only the
        // first `Text` of a multi-child `HStack` actually paints. Concatenate
        // segments into one `Text` so every enabled component shows up.
        let combined = segments.map(\.text).joined(separator: " · ")
        HStack(spacing: 4) {
            if combined.isEmpty {
                Image(systemName: "chart.bar.xaxis")
            } else {
                Text(combined)
                    .monospacedDigit()
                    .stxNumericValueTransition(value: combined)
            }
        }
        .accessibilityLabel(accessibilityLabel(segments: segments))
    }

    private var enabledSegments: [Segment] {
        env.preferences.menuBarItems
            .filter(\.isEnabled)
            .map { Segment(text: text(for: $0)) }
    }

    private func accessibilityLabel(segments: [Segment]) -> String {
        let header = "\(env.preferences.selectedProvider.shortName) Stats"
        guard !segments.isEmpty else { return header }
        return header + " — " + segments.map(\.text).joined(separator: ", ")
    }

    private func text(for item: MenuBarItem) -> String {
        let prefs = env.preferences
        let provider = prefs.selectedProvider
        let isFirstScan = env.store.sessions(for: provider).isEmpty && env.store.isLoading

        switch item.kind {
        case .tokens:
            if isFirstScan { return "…" }
            let summary = env.store.summary(for: item.period, provider: provider)
            return Format.tokens(summary.totalTokens(includingCacheRead: item.includesCache))
        case .cost:
            if isFirstScan { return "…" }
            let summary = env.store.summary(for: item.period, provider: provider)
            return Format.cost(summary.totalCost(for: prefs.costEstimationMode))
        case .fiveHourUsage:
            switch item.displayMode {
            case .percent:
                return percentText(forWindowID: "five_hour", fallbackLabel: "5h")
            case .remainingTime:
                return remainingText(forWindowID: "five_hour", fallbackLabel: "5h")
            case .resetTime:
                return resetTimeText(forWindowID: "five_hour", fallbackLabel: "5h")
            }
        case .sevenDayUsage:
            switch item.displayMode {
            case .percent:
                return percentText(forWindowID: "seven_day", fallbackLabel: "7d")
            case .remainingTime:
                return remainingText(forWindowID: "seven_day", fallbackLabel: "7d")
            case .resetTime:
                return resetTimeText(forWindowID: "seven_day", fallbackLabel: "7d")
            }
        case .fiveHourPrediction:
            return predictionText()
        }
    }

    private func percentText(forWindowID id: String, fallbackLabel: String) -> String {
        let provider = env.preferences.selectedProvider
        guard let snapshot = env.usageLimits.report(for: provider)?.snapshot,
              let window = snapshot.windows.first(where: { $0.id == id })
        else { return "\(fallbackLabel) —" }
        return "\(window.label) \(Format.percentPoints(window.clampedUsedPercent))"
    }

    /// "Remaining time" mode: prefix the percent with the duration left
    /// until the window's `resetAt` (e.g. `3h 0m 42%`). When the snapshot
    /// or `resetAt` is missing, fall through to the default prefix
    /// (`5h —` / `5h 42%`) so the user still sees something useful.
    private func remainingText(forWindowID id: String, fallbackLabel: String) -> String {
        let provider = env.preferences.selectedProvider
        guard let snapshot = env.usageLimits.report(for: provider)?.snapshot,
              let window = snapshot.windows.first(where: { $0.id == id }),
              let resetAt = window.resetAt
        else { return percentText(forWindowID: id, fallbackLabel: fallbackLabel) }
        let remaining = max(0, resetAt.timeIntervalSince(.now))
        return "\(Format.duration(remaining)) \(Format.percentPoints(window.clampedUsedPercent))"
    }

    /// "Reset time" mode: prefix the percent with the wall-clock of the
    /// next `resetAt` — `HH:mm` when reset is today, `MM/dd HH:mm`
    /// otherwise so a reset multiple days out is still unambiguous. Falls
    /// through to the default prefix on missing data, same as
    /// ``remainingText(forWindowID:fallbackLabel:)``.
    private func resetTimeText(forWindowID id: String, fallbackLabel: String) -> String {
        let provider = env.preferences.selectedProvider
        guard let snapshot = env.usageLimits.report(for: provider)?.snapshot,
              let window = snapshot.windows.first(where: { $0.id == id }),
              let resetAt = window.resetAt
        else { return percentText(forWindowID: id, fallbackLabel: fallbackLabel) }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = Calendar.current.isDateInToday(resetAt) ? "HH:mm" : "MM/dd HH:mm"
        return "\(formatter.string(from: resetAt)) \(Format.percentPoints(window.clampedUsedPercent))"
    }

    private func predictionText() -> String {
        let provider = env.preferences.selectedProvider
        guard env.usageLimits.report(for: provider)?.snapshot != nil else { return "⏱ —" }
        guard let estimate = env.usageLimits.trendEstimate(for: provider, windowID: "five_hour") else {
            return "⏱ 采样中"
        }
        return "⏱ \(Format.duration(TimeInterval(estimate.minutesUntilExhaust * 60)))"
    }

    private struct Segment {
        let text: String
    }
}

#if DEBUG
// Standalone preview of the status-item content only. The label actually
// lives in the system menu bar via `MenuBarExtra` — a `Scene`, which Xcode's
// Canvas can't render. Run the app (`bash scripts/run-debug.sh`) to see it
// in the real menu bar.
#Preview("Menu bar label") {
    VStack(alignment: .leading, spacing: 14) {
        MenuBarLabel().environment(AppEnvironment.preview())
        MenuBarLabel().environment(AppEnvironment.preview())
            .environment(\.colorScheme, .dark)
            .padding(6)
            .background(.black)
        MenuBarLabel().environment(AppEnvironment.preview(populated: false))
    }
    .padding()
}
#endif
