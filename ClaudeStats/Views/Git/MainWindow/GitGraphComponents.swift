import SwiftUI

/// Shared row renderer for git DAG lists. It draws the lane rail, commit node,
/// refs, author avatar, subject, and relative date while leaving selection
/// semantics to the parent view.
struct GitGraphRowView: View {
    let row: GraphLayout.Row
    let rowHeight: CGFloat
    let laneSpacing: CGFloat
    let railPad: CGFloat
    let nodeRadius: CGFloat
    let railWidth: CGFloat
    let isSelected: Bool
    var connectsFromTop = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GitGraphRailView(
                    row: row,
                    laneSpacing: laneSpacing,
                    railPad: railPad,
                    nodeRadius: nodeRadius,
                    connectsFromTop: connectsFromTop
                )
                .frame(width: railWidth)

                GitAvatar(name: row.commit.author, email: row.commit.authorEmail)
                    .frame(width: 20, height: 20)

                commitContent
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
                    .mask(TrailingFadeMask(width: 34))

                Text(Format.relativeDate(row.commit.date))
                    .font(.sora(9).monospacedDigit())
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
                    .fixedSize()
                    .help(Format.shortDate(row.commit.date))
            }
            .padding(.trailing, 14)
            .frame(height: rowHeight)
            .background((hovering || isSelected) ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(accessibilityTitle))
    }

    private var accessibilityTitle: String {
        "\(row.commit.shortHash), \(row.commit.author), \(row.commit.subject)"
    }

    private var commitContent: some View {
        HStack(spacing: 8) {
            ForEach(Array(row.commit.refs.enumerated()), id: \.offset) { _, ref in
                GitRefPill(ref: ref)
            }

            Text(TitleSanitizer.sanitize(row.commit.subject) ?? row.commit.subject)
                .font(.sora(11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

private struct GitGraphRailView: View {
    let row: GraphLayout.Row
    let laneSpacing: CGFloat
    let railPad: CGFloat
    let nodeRadius: CGFloat
    let connectsFromTop: Bool

    private func x(_ column: Int) -> CGFloat { railPad + CGFloat(column) * laneSpacing }
    private func color(_ idx: Int) -> Color { Color.stxRamp[idx % Color.stxRamp.count] }

    var body: some View {
        Canvas { ctx, size in
            let h = size.height
            let midY = h / 2

            for lane in row.passThrough {
                var p = Path()
                p.move(to: CGPoint(x: x(lane.column), y: 0))
                p.addLine(to: CGPoint(x: x(lane.column), y: h))
                ctx.stroke(p, with: .color(color(lane.colorIndex)), lineWidth: 1.6)
            }

            if connectsFromTop || !row.isBranchTip {
                var p = Path()
                p.move(to: CGPoint(x: x(row.column), y: 0))
                p.addLine(to: CGPoint(x: x(row.column), y: midY))
                ctx.stroke(p, with: .color(color(row.colorIndex)), lineWidth: 1.6)
            }

            for e in row.edgesDown {
                var p = Path()
                let xf = x(e.fromColumn), xt = x(e.toColumn)
                p.move(to: CGPoint(x: xf, y: midY))
                if xf == xt {
                    p.addLine(to: CGPoint(x: xt, y: h))
                } else {
                    p.addCurve(
                        to: CGPoint(x: xt, y: h),
                        control1: CGPoint(x: xf, y: h * 0.78),
                        control2: CGPoint(x: xt, y: midY + (h - midY) * 0.22)
                    )
                }
                ctx.stroke(p, with: .color(color(e.colorIndex)), lineWidth: 1.6)
            }

            let c = CGPoint(x: x(row.column), y: midY)
            let disc = Path(ellipseIn: CGRect(
                x: c.x - nodeRadius,
                y: c.y - nodeRadius,
                width: nodeRadius * 2,
                height: nodeRadius * 2
            ))
            ctx.fill(disc, with: .color(color(row.colorIndex)))
            if row.commit.isMerge {
                let ringRadius = nodeRadius + 2.5
                let ring = Path(ellipseIn: CGRect(
                    x: c.x - ringRadius,
                    y: c.y - ringRadius,
                    width: ringRadius * 2,
                    height: ringRadius * 2
                ))
                ctx.stroke(ring, with: .color(color(row.colorIndex)), lineWidth: 1.6)
            }
        }
    }
}

struct GitWorkingTreeRowView: View {
    let summary: GitWorkingTreeSummary
    let rowHeight: CGFloat
    let railPad: CGFloat
    let nodeRadius: CGFloat
    let railWidth: CGFloat
    let railColorIndex: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                GitWorkingTreeRailView(
                    railPad: railPad,
                    nodeRadius: nodeRadius,
                    railColorIndex: railColorIndex
                )
                    .frame(width: railWidth)

                GitWorkingTreeIcon()
                    .frame(width: 20, height: 20)

                Text(summary.title)
                    .font(.sora(13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 8)
            }
            .padding(.trailing, 14)
            .frame(height: rowHeight)
            .background((hovering || isSelected) ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(summary.title))
    }
}

private struct GitWorkingTreeRailView: View {
    let railPad: CGFloat
    let nodeRadius: CGFloat
    let railColorIndex: Int

    private func color(_ idx: Int) -> Color { Color.stxRamp[idx % Color.stxRamp.count] }

    var body: some View {
        Canvas { ctx, size in
            let midY = size.height / 2
            let railColor = color(railColorIndex)
            var p = Path()
            p.move(to: CGPoint(x: railPad, y: midY + nodeRadius + 2))
            p.addLine(to: CGPoint(x: railPad, y: size.height))
            ctx.stroke(
                p,
                with: .color(railColor),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 4])
            )

            let c = CGPoint(x: railPad, y: midY)
            let ring = Path(ellipseIn: CGRect(
                x: c.x - nodeRadius - 2,
                y: c.y - nodeRadius - 2,
                width: (nodeRadius + 2) * 2,
                height: (nodeRadius + 2) * 2
            ))
            ctx.fill(ring, with: .color(Color.stxBackground))
            ctx.stroke(ring, with: .color(railColor), lineWidth: 1.8)
        }
    }
}

private struct GitWorkingTreeIcon: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(
                Color.stxMuted.opacity(0.55),
                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
            )
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.primary.opacity(0.025))
            )
    }
}

struct GitWorkingTreeKindPill: View {
    let kind: GitWorkingTreeChange.Kind

    private var tint: Color {
        switch kind {
        case .added, .copied, .untracked: return GitPalette.add
        case .deleted: return GitPalette.del
        case .renamed: return GitPalette.tag
        case .conflicted: return Color.red
        case .modified, .changed: return GitPalette.head
        }
    }

    var body: some View {
        Text(kind.shortLabel)
            .font(.sora(8, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
            .frame(width: 28, alignment: .leading)
            .help(kind.label)
    }
}

/// The `[ ‹ ]` back button used in git drill-in views. Brightens and shows a
/// faint pill on hover so it reads as a target.
struct GitBackButton: View {
    var help: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("[")
                    .foregroundStyle(Color.stxBracket)
                    .offset(y: -1)
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering ? Color.primary : Color.stxMuted)
                Text("]")
                    .foregroundStyle(Color.stxBracket)
                    .offset(y: -1)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .help(help)
    }
}

struct GitRefPill: View {
    let ref: GitRef

    private var tint: Color {
        switch ref.kind {
        case .head: GitPalette.head
        case .tag: GitPalette.tag
        case .branch: Color.primary.opacity(0.45)
        }
    }

    var body: some View {
        Text(ref.name)
            .font(.sora(8, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(ref.kind == .branch ? 0.16 : 0.85), in: Capsule())
            .foregroundStyle(ref.kind == .branch ? Color.primary : Color.white)
            .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: ref.kind == .branch ? 1 : 0))
            .fixedSize()
    }
}

/// Initials avatar with a colour deterministically derived from the email.
struct GitAvatar: View {
    let name: String
    let email: String

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "." }).prefix(2)
        let chars = words.compactMap(\.first).map { String($0).uppercased() }
        if chars.isEmpty { return "?" }
        return chars.joined()
    }

    private var color: Color {
        var h: UInt64 = 0xcbf29ce484222325
        for b in email.lowercased().utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hue = Double(h % 360) / 360.0
        return Color(hue: hue, saturation: 0.42, brightness: 0.62)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .overlay(
                Text(initials)
                    .font(.sora(8, weight: .bold))
                    .foregroundStyle(.white)
            )
    }
}
