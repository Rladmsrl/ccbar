import Testing
@testable import ClaudeStats

@Suite("Git code ownership analyzer")
struct GitCodeOwnershipAnalyzerTests {
    @Test("porcelain blame parser reuses commit metadata and skips blank lines")
    func porcelainParserReusesCommitMetadata() throws {
        let adaHash = String(repeating: "a", count: 40)
        let blame = """
        \(adaHash) 1 1 3
        author Ada
        author-mail <ada@example.com>
        filename Sources/App.swift
        \tlet a = 1
        \(adaHash) 2 2
        filename Sources/App.swift
        \t   
        \(adaHash) 3 3
        filename Sources/App.swift
        \tlet b = 2
        """

        let counters = GitCodeOwnershipAnalyzer.parsePorcelainBlameCounters(blame)
        let ada = try #require(counters.first)

        #expect(counters.count == 1)
        #expect(ada.name == "Ada")
        #expect(ada.email == "ada@example.com")
        #expect(ada.lineCount == 2)
    }

    @Test("counter merge recomputes line shares across files")
    func counterMergeRecomputesShares() throws {
        let adaHash = String(repeating: "a", count: 40)
        let bobHash = String(repeating: "b", count: 40)
        let fileA = """
        \(adaHash) 1 1
        author Ada
        author-mail <ada@example.com>
        filename A.swift
        \tlet a = 1
        \(adaHash) 2 2
        filename A.swift
        \tlet b = 2
        """
        let fileB = """
        \(adaHash) 1 1
        author Ada
        author-mail <ada@example.com>
        filename B.swift
        \tlet c = 3
        \(bobHash) 2 2
        author Bob
        author-mail <bob@example.com>
        filename B.swift
        \tlet d = 4
        \(bobHash) 3 3
        filename B.swift
        \tlet e = 5
        \(bobHash) 4 4
        filename B.swift
        \tlet f = 6
        """

        let counters = GitCodeOwnershipAnalyzer.parsePorcelainBlameCounters(fileA)
            + GitCodeOwnershipAnalyzer.parsePorcelainBlameCounters(fileB)
        let stats = GitCodeOwnershipAnalyzer.stats(from: counters)

        #expect(stats.map(\.displayName) == ["Ada <ada@example.com>", "Bob <bob@example.com>"])
        #expect(stats.map(\.lineCount) == [3, 3])
        #expect(stats.allSatisfy { $0.share == 0.5 })
    }
}
