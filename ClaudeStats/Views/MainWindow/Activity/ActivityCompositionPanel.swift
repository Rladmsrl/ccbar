import SwiftUI

struct ActivityCompositionPanel: View {
    let title: String
    let caption: String
    let split: ActivityTimeSplit

    init(activity: DayActivity?) {
        self.title = "TIME SPLIT"
        self.caption = "Surface overlap, CLI host time, and AI activity outside focused coding apps."
        self.split = ActivityTimeSplit(activity: activity)
    }

    init(trend: [DayActivity]) {
        self.title = "AGGREGATE SPLIT"
        self.caption = "Total time split across the selected range."
        self.split = ActivityTimeSplit(days: trend)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.sora(13, weight: .semibold))
                    .tracking(1.0)
                Spacer()
                Text(split.totalSeconds > 0 ? Format.duration(split.totalSeconds) : "--")
                    .font(.sora(12, weight: .semibold).monospacedDigit())
                    .stxNumericValueTransition(value: split.totalSeconds > 0 ? Format.duration(split.totalSeconds) : "--")
                    .foregroundStyle(.primary)
                    .help("Total split time")
            }

            Text(caption)
                .font(.sora(10))
                .foregroundStyle(Color.stxMuted)
                .fixedSize(horizontal: false, vertical: true)

            if split.totalSeconds <= 0 {
                Text("Nothing to break down for this selection.")
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
            } else {
                compositionBar
                rows
            }
        }
        .mainWindowPanel(padding: 16)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private var compositionBar: some View {
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(split.parts) { part in
                    let width = proxy.size.width * CGFloat(part.seconds / max(1, split.totalSeconds))
                    Rectangle()
                        .fill(part.color)
                        .frame(width: max(part.seconds > 0 ? CGFloat(2) : 0, width))
                }
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
        }
        .frame(height: 8)
        .accessibilityLabel("Time split bar")
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(split.parts) { part in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(part.color)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                    Text(part.label)
                        .font(.sora(11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.duration(part.seconds))
                        .font(.sora(11).monospacedDigit())
                        .stxNumericValueTransition(value: Format.duration(part.seconds))
                        .foregroundStyle(Color.stxMuted)
                        .frame(minWidth: 72, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(part.label), \(Format.duration(part.seconds))")
            }
        }
    }
}

struct ActivityTimeSplit: Equatable {
    struct Part: Identifiable, Equatable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let color: Color

        static func == (lhs: Part, rhs: Part) -> Bool {
            lhs.id == rhs.id && lhs.label == rhs.label && lhs.seconds == rhs.seconds
        }
    }

    var overlapSeconds: TimeInterval
    var soloCodingSurfaceSeconds: TimeInterval
    var cliAIOverlapSeconds: TimeInterval
    var cliHostOnlySeconds: TimeInterval
    var aiOnlySeconds: TimeInterval

    var totalSeconds: TimeInterval {
        overlapSeconds + soloCodingSurfaceSeconds + cliAIOverlapSeconds + cliHostOnlySeconds + aiOnlySeconds
    }

    var parts: [Part] {
        [
            Part(id: "overlap", label: "AI-assisted coding", seconds: overlapSeconds, color: Color.stxAccent),
            Part(id: "solo-surface", label: "Solo coding surface", seconds: soloCodingSurfaceSeconds, color: Color.primary.opacity(0.26)),
            Part(id: "cli-ai", label: "CLI + AI", seconds: cliAIOverlapSeconds, color: Color.blue.opacity(0.72)),
            Part(id: "cli-only", label: "CLI host only", seconds: cliHostOnlySeconds, color: Color.blue.opacity(0.30)),
            Part(id: "ai-only", label: "AI outside surface/CLI", seconds: aiOnlySeconds, color: Color.stxAccent.opacity(0.40)),
        ]
    }

    init(activity: DayActivity?) {
        let cliAI = activity?.cliAIOverlapSeconds ?? 0
        overlapSeconds = activity?.overlapSeconds ?? 0
        soloCodingSurfaceSeconds = activity?.soloCodingSurfaceSeconds ?? 0
        cliAIOverlapSeconds = cliAI
        cliHostOnlySeconds = max(0, (activity?.cliHostSeconds ?? 0) - cliAI)
        aiOnlySeconds = activity?.aiOnlySeconds ?? 0
    }

    init(days: [DayActivity]) {
        overlapSeconds = days.reduce(0) { $0 + $1.overlapSeconds }
        soloCodingSurfaceSeconds = days.reduce(0) { $0 + $1.soloCodingSurfaceSeconds }
        cliAIOverlapSeconds = days.reduce(0) { $0 + $1.cliAIOverlapSeconds }
        cliHostOnlySeconds = days.reduce(0) { $0 + max(0, $1.cliHostSeconds - $1.cliAIOverlapSeconds) }
        aiOnlySeconds = days.reduce(0) { $0 + $1.aiOnlySeconds }
    }
}

#if DEBUG
#Preview {
    ActivityCompositionPanel(activity: nil)
        .padding(24)
        .frame(width: 360)
        .background(Color.stxBackground)
}
#endif
