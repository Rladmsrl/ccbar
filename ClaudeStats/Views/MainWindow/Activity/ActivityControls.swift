import SwiftUI

struct ActivityControls: View {
    @Binding var range: ActivityRange
    let selectedDay: Date
    let canStepForward: Bool
    let isLoading: Bool
    let onStepDay: (Int) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ActivityRangeChips(range: $range)

            if range == .day {
                dayStepper
                    .transition(.opacity)
            } else {
                Text("Last \(range.dayCount) days")
                    .font(.sora(11, weight: .medium))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Loading activity")
            }
        }
        .animation(.easeOut(duration: 0.18), value: range)
    }

    private var dayStepper: some View {
        PillTimeStepperBar(
            canStepForward: canStepForward,
            isCenterSelected: true,
            previousHelp: "Previous day",
            nextHelp: "Next day",
            centerAccessibilityLabel: "Selected day",
            accessibilityLabel: "Day navigation",
            onPrevious: {
                onStepDay(-1)
            },
            onNext: {
                onStepDay(1)
            }
        ) { _ in
            Text(Format.day(selectedDay))
        }
    }
}

private struct ActivityRangeChips: View {
    @Binding var range: ActivityRange

    var body: some View {
        PillSegmentedBar(
            ActivityRange.allCases,
            selection: $range,
            help: { $0 == .day ? "Show one day" : "Show last \($0.dayCount) days" },
            accessibilityLabel: { $0 == .day ? "Day" : "Last \($0.dayCount) days" }
        ) { value, _ in
            Text(value.mainWindowLabel)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Activity range")
    }
}

#if DEBUG
#Preview {
    struct Wrap: View {
        @State private var range = ActivityRange.day
        var body: some View {
            ActivityControls(
                range: $range,
                selectedDay: .now,
                canStepForward: false,
                isLoading: false,
                onStepDay: { _ in }
            )
            .padding(24)
            .frame(width: 720)
            .background(Color.stxBackground)
        }
    }

    return Wrap()
}
#endif
