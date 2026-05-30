import SwiftUI

struct WorkspaceColumnsLayout: Layout {
    let railWidth: CGFloat
    let listWidth: CGFloat
    let detailMinWidth: CGFloat
    let spacing: CGFloat

    struct Cache {
        private var measuredSizes: [MeasurementKey: CGSize] = [:]

        mutating func size(
            for index: Int,
            width: CGFloat,
            measure: () -> CGSize
        ) -> CGSize {
            let key = MeasurementKey(index: index, width: width)
            if let size = measuredSizes[key] {
                return size
            }
            let size = measure()
            measuredSizes[key] = size
            return size
        }

        mutating func reset() {
            measuredSizes.removeAll(keepingCapacity: true)
        }
    }

    private struct MeasurementKey: Hashable {
        let index: Int
        let width: Int

        init(index: Int, width: CGFloat) {
            self.index = index
            self.width = Int((width * 2).rounded())
        }
    }

    private var stackedSpacing: CGFloat {
        min(spacing, 8)
    }

    private var wideMinimumWidth: CGFloat {
        railWidth + listWidth + detailMinWidth + spacing * 2
    }

    private var narrowWidth: CGFloat {
        railWidth + listWidth + spacing
    }

    func makeCache(subviews _: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews _: Subviews) {
        cache.reset()
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard subviews.count == 3 else { return .zero }

        let availableWidth = proposal.width ?? wideMinimumWidth
        if availableWidth >= wideMinimumWidth {
            let detailWidth = max(detailMinWidth, availableWidth - railWidth - listWidth - spacing * 2)
            let detailSize = measuredSize(index: 2, width: detailWidth, subviews: subviews, cache: &cache)
            return CGSize(
                width: railWidth + listWidth + detailWidth + spacing * 2,
                height: detailSize.height
            )
        } else {
            let layoutWidth = max(availableWidth, narrowWidth)
            let rightColumnWidth = max(listWidth, layoutWidth - railWidth - spacing)
            let detailSize = measuredSize(index: 2, width: rightColumnWidth, subviews: subviews, cache: &cache)
            let listHeight = narrowListHeight(
                subviews: subviews,
                width: rightColumnWidth,
                maxHeight: detailSize.height,
                cache: &cache
            )
            return CGSize(
                width: layoutWidth,
                height: listHeight + stackedSpacing + detailSize.height
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard subviews.count == 3 else { return }

        if bounds.width >= wideMinimumWidth {
            placeWide(in: bounds, subviews: subviews, cache: &cache)
        } else {
            placeNarrow(in: bounds, subviews: subviews, cache: &cache)
        }
    }

    private func placeWide(in bounds: CGRect, subviews: Subviews, cache: inout Cache) {
        let detailWidth = max(detailMinWidth, bounds.width - railWidth - listWidth - spacing * 2)
        let detailSize = measuredSize(index: 2, width: detailWidth, subviews: subviews, cache: &cache)
        let columnHeight = detailSize.height

        var x = bounds.minX
        subviews[0].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: railWidth, height: columnHeight)
        )

        x += railWidth + spacing
        subviews[1].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: listWidth, height: columnHeight)
        )

        x += listWidth + spacing
        subviews[2].place(
            at: CGPoint(x: x, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: detailWidth, height: nil)
        )
    }

    private func placeNarrow(in bounds: CGRect, subviews: Subviews, cache: inout Cache) {
        let rightColumnWidth = max(listWidth, bounds.width - railWidth - spacing)
        let detailSize = measuredSize(index: 2, width: rightColumnWidth, subviews: subviews, cache: &cache)
        let listHeight = narrowListHeight(
            subviews: subviews,
            width: rightColumnWidth,
            maxHeight: detailSize.height,
            cache: &cache
        )
        let stackedHeight = listHeight + stackedSpacing + detailSize.height
        let originX = bounds.minX
        let rightX = originX + railWidth + spacing

        subviews[0].place(
            at: CGPoint(x: originX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: railWidth, height: stackedHeight)
        )
        subviews[1].place(
            at: CGPoint(x: rightX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: rightColumnWidth, height: listHeight)
        )
        subviews[2].place(
            at: CGPoint(x: rightX, y: bounds.minY + listHeight + stackedSpacing),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: rightColumnWidth, height: nil)
        )
    }

    private func narrowListHeight(subviews: Subviews, width: CGFloat, maxHeight: CGFloat, cache: inout Cache) -> CGFloat {
        let naturalHeight = measuredSize(index: 1, width: width, subviews: subviews, cache: &cache).height
        return min(naturalHeight, maxHeight)
    }

    private func measuredSize(index: Int, width: CGFloat, subviews: Subviews, cache: inout Cache) -> CGSize {
        cache.size(for: index, width: width) {
            subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}
