import SwiftUI

/// Reusable pill-style segmented bar for compact mode switches.
///
/// The default dashboard style has a 25pt selected item plus 3pt outer inset,
/// so the full control height is 31pt.
struct PillSegmentedBar<Option: Identifiable & Equatable, Label: View>: View {
    let options: [Option]
    @Binding var selection: Option
    var style: PillSegmentedBarStyle
    var help: ((Option) -> String?)?
    var accessibilityLabel: ((Option) -> String?)?
    var onSelect: ((Option) -> Void)?
    var label: (Option, Bool) -> Label

    @Namespace private var namespace

    init(
        _ options: [Option],
        selection: Binding<Option>,
        style: PillSegmentedBarStyle = .standard,
        help: ((Option) -> String?)? = nil,
        accessibilityLabel: ((Option) -> String?)? = nil,
        onSelect: ((Option) -> Void)? = nil,
        @ViewBuilder label: @escaping (Option, Bool) -> Label
    ) {
        self.options = options
        _selection = selection
        self.style = style
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.onSelect = onSelect
        self.label = label
    }

    var body: some View {
        HStack(spacing: style.itemSpacing) {
            ForEach(options) { option in
                item(option)
            }
        }
        .padding(style.outerPadding)
        .background(
            RoundedRectangle(cornerRadius: style.outerCornerRadius, style: .continuous)
                .fill(style.background)
        )
    }

    private func item(_ option: Option) -> some View {
        let isSelected = selection == option
        return Button {
            if selection != option {
                withAnimation(style.selectionAnimation) {
                    selection = option
                }
            }
            onSelect?(option)
        } label: {
            label(option, isSelected)
                .font(style.font)
                .foregroundStyle(isSelected ? style.selectedForeground : style.unselectedForeground)
                .lineLimit(1)
                .padding(.horizontal, style.itemHorizontalPadding)
                .frame(height: style.itemHeight)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: style.selectedCornerRadius, style: .continuous)
                            .fill(style.selectedBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: style.selectedCornerRadius, style: .continuous)
                                    .strokeBorder(style.selectedBorder, lineWidth: style.selectedBorderWidth)
                            )
                            .matchedGeometryEffect(id: "selected-pill", in: namespace)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pillSegmentedHelp(help?(option))
        .pillSegmentedAccessibilityLabel(accessibilityLabel?(option))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct PillSegmentedBarStyle {
    var itemSpacing: CGFloat
    var outerPadding: CGFloat
    var outerCornerRadius: CGFloat
    var selectedCornerRadius: CGFloat
    var itemHorizontalPadding: CGFloat
    var itemHeight: CGFloat
    var font: Font
    var background: Color
    var selectedBackground: Color
    var selectedBorder: Color
    var selectedBorderWidth: CGFloat
    var selectedForeground: Color
    var unselectedForeground: Color
    var selectionAnimation: Animation?

    var totalHeight: CGFloat {
        itemHeight + outerPadding * 2
    }
}

extension PillSegmentedBarStyle {
    static let standard = PillSegmentedBarStyle(
        itemSpacing: 2,
        outerPadding: 3,
        outerCornerRadius: 8,
        selectedCornerRadius: 6,
        itemHorizontalPadding: 12,
        itemHeight: 25,
        font: .sora(12, weight: .medium),
        background: Color.primary.opacity(0.06),
        selectedBackground: AppSurface.pillSelectedFill,
        selectedBorder: AppSurface.pillSelectedStroke,
        selectedBorderWidth: 1,
        selectedForeground: Color.primary,
        unselectedForeground: Color.stxMuted,
        selectionAnimation: .easeOut(duration: 0.18)
    )
}

private extension View {
    @ViewBuilder
    func pillSegmentedHelp(_ help: String?) -> some View {
        if let help {
            self.help(help)
        } else {
            self
        }
    }

    @ViewBuilder
    func pillSegmentedAccessibilityLabel(_ label: String?) -> some View {
        if let label {
            self.accessibilityLabel(Text(label))
        } else {
            self
        }
    }
}

#if DEBUG
private enum PillSegmentedBarPreviewMode: String, CaseIterable, Identifiable {
    case overview
    case models

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .models: "Models"
        }
    }
}

#Preview {
    struct Wrap: View {
        @State var mode: PillSegmentedBarPreviewMode = .overview

        var body: some View {
            PillSegmentedBar(PillSegmentedBarPreviewMode.allCases, selection: $mode) { option, _ in
                Text(option.title)
            }
            .padding(24)
            .frame(width: 360)
        }
    }

    return Wrap().background(Color.stxBackground)
}
#endif
