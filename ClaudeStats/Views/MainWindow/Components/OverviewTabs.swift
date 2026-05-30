import SwiftUI

/// Dashboard-specific wrapper around the reusable pill segmented bar.
struct OverviewTabs: View {
    @Binding var section: DashboardViewModel.Section

    var body: some View {
        PillSegmentedBar(
            Array(DashboardViewModel.Section.allCases),
            selection: $section
        ) { option, _ in
            Text(LocalizedStringKey(Self.label(for: option)))
        }
    }

    private static func label(for section: DashboardViewModel.Section) -> String {
        switch section {
        case .overview: "Overview"
        case .models: "Models"
        }
    }
}

#if DEBUG
#Preview {
    struct Wrap: View {
        @State var sec: DashboardViewModel.Section = .overview
        var body: some View {
            OverviewTabs(section: $sec).padding(24).frame(width: 360)
        }
    }
    return Wrap().background(Color.stxBackground)
}
#endif
