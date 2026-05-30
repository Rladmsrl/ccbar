import Foundation

/// Lane assignment for a commit DAG — the "active lanes" sweep that gitk and
/// friends use. Pure and `Sendable`; computed once per loaded graph.
///
/// For each row we record the node's lane (`column`), the lanes that merely
/// cross the row (`passThrough`), and the connections leaving the node toward
/// its parents (`edgesDown`, drawn in the row's lower half). Bends only ever
/// happen in the lower half of the commit that creates the edge — every other
/// segment is a straight vertical — so each row can be drawn independently
/// (keeping a `LazyVStack` lazy).
struct GraphLayout: Sendable {
    struct Lane: Sendable, Hashable {
        let column: Int
        let colorIndex: Int
    }
    struct Edge: Sendable, Hashable {
        /// Node's column at the row's mid-height.
        let fromColumn: Int
        /// Parent's column at the row's bottom edge (== `fromColumn` ⇒ straight).
        let toColumn: Int
        let colorIndex: Int
    }
    struct Row: Sendable, Identifiable {
        let commit: GraphCommit
        let column: Int
        let colorIndex: Int
        /// `true` when no newer shown commit references this one — i.e. a branch
        /// tip; the renderer then omits the segment from the row's top edge to
        /// the node (there is nothing above to connect to).
        let isBranchTip: Bool
        let passThrough: [Lane]
        let edgesDown: [Edge]
        var id: String { commit.id }
    }

    let rows: [Row]
    /// Highest lane index used anywhere — for sizing the rail.
    let maxColumn: Int

    static func build(_ commits: [GraphCommit]) -> GraphLayout {
        // activeLanes[i] = hash the lane is reserved for (the next processed
        // commit with that hash lands in lane i), or nil when the lane is free.
        var activeLanes: [String?] = []
        var colorOf: [Int] = []
        var nextColor = 0
        var maxColumn = 0
        var rows: [Row] = []

        func freeLane() -> Int {
            if let i = activeLanes.firstIndex(where: { $0 == nil }) { return i }
            activeLanes.append(nil)
            colorOf.append(0)
            return activeLanes.count - 1
        }
        func paint(_ lane: Int) -> Int {
            defer { nextColor += 1 }
            colorOf[lane] = nextColor
            return nextColor
        }

        for commit in commits {
            // Lanes that already existed entering this row — only these are drawn
            // as full-height pass-throughs; lanes created here (new merge parents)
            // are only reached via `edgesDown`.
            let activeBefore = Set(activeLanes.indices.filter { activeLanes[$0] != nil })
            let reserved = activeLanes.indices.filter { activeLanes[$0] == commit.hash }
            let column: Int
            let colorIndex: Int
            if let first = reserved.first {
                column = first
                colorIndex = colorOf[first]
                for dup in reserved.dropFirst() { activeLanes[dup] = nil }   // collapse re-merged lanes
            } else {
                column = freeLane()
                colorIndex = paint(column)
            }
            maxColumn = max(maxColumn, column)

            var edges: [Edge] = []
            if let firstParent = commit.parentHashes.first {
                if let existing = activeLanes.firstIndex(where: { $0 == firstParent }) {
                    edges.append(Edge(fromColumn: column, toColumn: existing, colorIndex: colorOf[existing]))
                    if existing != column { activeLanes[column] = nil }
                } else {
                    activeLanes[column] = firstParent
                    edges.append(Edge(fromColumn: column, toColumn: column, colorIndex: colorIndex))
                }
                for parent in commit.parentHashes.dropFirst() {
                    if let existing = activeLanes.firstIndex(where: { $0 == parent }) {
                        edges.append(Edge(fromColumn: column, toColumn: existing, colorIndex: colorOf[existing]))
                    } else {
                        let lane = freeLane()
                        activeLanes[lane] = parent
                        let c = paint(lane)
                        edges.append(Edge(fromColumn: column, toColumn: lane, colorIndex: c))
                        maxColumn = max(maxColumn, lane)
                    }
                }
            } else {
                activeLanes[column] = nil   // root commit — lane ends here
            }

            let passThrough: [Lane] = activeLanes.indices.compactMap { idx in
                guard idx != column, activeLanes[idx] != nil, activeBefore.contains(idx) else { return nil }
                maxColumn = max(maxColumn, idx)
                return Lane(column: idx, colorIndex: colorOf[idx])
            }

            rows.append(Row(commit: commit, column: column, colorIndex: colorIndex,
                            isBranchTip: reserved.isEmpty, passThrough: passThrough, edgesDown: edges))
        }
        return GraphLayout(rows: rows, maxColumn: maxColumn)
    }
}
