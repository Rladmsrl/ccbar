import Testing
import Foundation
@testable import ClaudeStats

@Suite("GitGraphLayout & graph parsing")
struct GitGraphLayoutTests {

    private func c(_ hash: String, _ parents: [String]) -> GraphCommit {
        GraphCommit(hash: hash, parentHashes: parents, refs: [], author: "A", authorEmail: "a@x",
                    date: .distantPast, subject: hash)
    }
    private func byHash(_ layout: GraphLayout) -> [String: GraphLayout.Row] {
        Dictionary(uniqueKeysWithValues: layout.rows.map { ($0.commit.hash, $0) })
    }

    @Test("linear history → single lane")
    func linear() {
        let layout = GraphLayout.build([c("A", ["B"]), c("B", ["C"]), c("C", ["D"]), c("D", [])])
        #expect(layout.maxColumn == 0)
        #expect(layout.rows.map(\.column) == [0, 0, 0, 0])
        #expect(layout.rows.allSatisfy { $0.colorIndex == 0 })
        #expect(layout.rows[0].isBranchTip)
        #expect(!layout.rows[1].isBranchTip)
        #expect(layout.rows.last?.edgesDown.isEmpty == true)            // root
        #expect(layout.rows[0].edgesDown == [GraphLayout.Edge(fromColumn: 0, toColumn: 0, colorIndex: 0)])
        #expect(layout.rows.allSatisfy { $0.passThrough.isEmpty })
    }

    @Test("feature branch that merges back")
    func branchAndMerge() {
        // M = merge(B, F); B and F are both children of A; A is the root.
        let layout = GraphLayout.build([c("M", ["B", "F"]), c("B", ["A"]), c("F", ["A"]), c("A", [])])
        let r = byHash(layout)
        #expect(layout.maxColumn == 1)
        #expect(r["M"]!.column == 0)
        #expect(r["M"]!.isBranchTip)
        #expect(r["M"]!.edgesDown.contains(GraphLayout.Edge(fromColumn: 0, toColumn: 0, colorIndex: 0)))
        #expect(r["M"]!.edgesDown.contains { $0.fromColumn == 0 && $0.toColumn == 1 })
        #expect(r["M"]!.passThrough.isEmpty)                            // lane 1 is created in this row
        #expect(r["B"]!.column == 0)
        #expect(r["B"]!.passThrough.map(\.column) == [1])               // F's lane crosses B's row
        #expect(r["F"]!.column == 1)
        #expect(r["F"]!.edgesDown == [GraphLayout.Edge(fromColumn: 1, toColumn: 0, colorIndex: 0)])  // merges into mainline
        #expect(r["F"]!.passThrough.map(\.column) == [0])               // B→A crosses F's row
        #expect(r["A"]!.column == 0)
        #expect(r["A"]!.edgesDown.isEmpty)
        #expect(r["A"]!.passThrough.isEmpty)
    }

    @Test("octopus merge (3 parents)")
    func octopus() {
        let layout = GraphLayout.build([c("O", ["P1", "P2", "P3"]), c("P1", []), c("P2", []), c("P3", [])])
        let r = byHash(layout)
        #expect(r["O"]!.column == 0)
        #expect(r["O"]!.edgesDown.count == 3)
        #expect(Set(r["O"]!.edgesDown.map(\.toColumn)) == [0, 1, 2])
        #expect(layout.maxColumn == 2)
        #expect(r["P1"]!.column == 0)
        #expect(r["P2"]!.column == 1)
        #expect(r["P3"]!.column == 2)
        #expect(Set(r["P1"]!.passThrough.map(\.column)) == [1, 2])
        #expect(r["P2"]!.passThrough.map(\.column) == [2])
        #expect(r["P3"]!.passThrough.isEmpty)
    }

    @Test("two long-lived parallel branches, interleaved")
    func parallel() {
        // Lane 0: X1 → X2 → Base ; lane 1: Y1 → Y2 → Base ; Base is the shared root.
        let layout = GraphLayout.build([
            c("X1", ["X2"]), c("Y1", ["Y2"]), c("X2", ["Base"]), c("Y2", ["Base"]), c("Base", []),
        ])
        let r = byHash(layout)
        #expect(r["X1"]!.column == 0)
        #expect(r["Y1"]!.column == 1)
        #expect(r["X2"]!.column == 0)
        #expect(r["Y2"]!.column == 1)
        #expect(r["X1"]!.colorIndex != r["Y1"]!.colorIndex)
        #expect(r["Base"]!.column == 0)                                 // first reached via X2's first parent
        #expect(r["Y2"]!.edgesDown == [GraphLayout.Edge(fromColumn: 1, toColumn: 0, colorIndex: r["X1"]!.colorIndex)])
        #expect(layout.maxColumn == 1)
    }

    @Test("parent outside the shown window leaves a dangling lane, no crash")
    func truncatedParent() {
        let layout = GraphLayout.build([c("A", ["B"]), c("B", ["C"])])   // C is never shown
        #expect(layout.rows.count == 2)
        #expect(layout.rows[1].edgesDown == [GraphLayout.Edge(fromColumn: 0, toColumn: 0, colorIndex: 0)])
        #expect(layout.maxColumn == 0)
    }

    // MARK: - parseGraphLog / parseRefs

    private static let RS = "\u{1e}"
    private static let FS = "\u{1f}"

    @Test("parseGraphLog reads parents, refs, author, date, subject")
    func parseGraphLog() {
        let log = """
        \(Self.RS)aaa\(Self.FS)bbb ccc\(Self.FS)HEAD -> main, tag: v1.0, feature/x\(Self.FS)Ada\(Self.FS)ada@x.com\(Self.FS)1705314600\(Self.FS)Merge branch 'feature/x'
        \(Self.RS)bbb\(Self.FS)ddd\(Self.FS)\(Self.FS)Bo\(Self.FS)bo@x.com\(Self.FS)1705228200\(Self.FS)Plain commit
        """
        let commits = GitAnalyzer.parseGraphLog(log)
        #expect(commits.count == 2)
        let m = commits[0]
        #expect(m.hash == "aaa")
        #expect(m.parentHashes == ["bbb", "ccc"])
        #expect(m.isMerge)
        #expect(m.author == "Ada")
        #expect(m.authorEmail == "ada@x.com")
        #expect(m.date == Date(timeIntervalSince1970: 1_705_314_600))
        #expect(m.subject == "Merge branch 'feature/x'")
        #expect(m.refs.contains(GitRef(kind: .head, name: "main")))
        #expect(m.refs.contains(GitRef(kind: .tag, name: "v1.0")))
        #expect(m.refs.contains(GitRef(kind: .branch, name: "feature/x")))
        #expect(commits[1].parentHashes == ["ddd"])
        #expect(commits[1].refs.isEmpty)
        #expect(!commits[1].isMerge)
    }

    @Test("parseRefs handles HEAD, detached HEAD, tags, slashes")
    func parseRefs() {
        #expect(GitAnalyzer.parseRefs("") == [])
        #expect(GitAnalyzer.parseRefs("HEAD") == [GitRef(kind: .head, name: "HEAD")])
        #expect(GitAnalyzer.parseRefs("HEAD -> dev, origin-mirror, tag: r2") ==
                [GitRef(kind: .head, name: "dev"), GitRef(kind: .branch, name: "origin-mirror"), GitRef(kind: .tag, name: "r2")])
    }
}
