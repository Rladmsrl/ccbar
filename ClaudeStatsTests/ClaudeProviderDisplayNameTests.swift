import Testing
@testable import ClaudeStats

@Suite("ClaudeProvider.displayName")
struct ClaudeProviderDisplayNameTests {

    @Test("Modern family-major-minor ids: claude-opus-4-7 → Opus 4.7")
    func modernIds() {
        #expect(ClaudeProvider.prettyName(for: "claude-opus-4-7") == "Opus 4.7")
        #expect(ClaudeProvider.prettyName(for: "claude-sonnet-4-6") == "Sonnet 4.6")
        #expect(ClaudeProvider.prettyName(for: "claude-haiku-4-5") == "Haiku 4.5")
    }

    @Test("Legacy major.minor-family ids: claude-3.5-sonnet → Sonnet 3.5")
    func legacyIds() {
        #expect(ClaudeProvider.prettyName(for: "claude-3.5-sonnet") == "Sonnet 3.5")
        #expect(ClaudeProvider.prettyName(for: "claude-3-opus") == "Opus 3")
    }

    @Test("Family-only id with no minor: claude-opus-4 → Opus 4")
    func familyMajorOnly() {
        #expect(ClaudeProvider.prettyName(for: "claude-opus-4") == "Opus 4")
    }

    @Test("Unknown shapes fall back to a hyphen-cleaned, capitalised label")
    func unknownIds() {
        #expect(ClaudeProvider.prettyName(for: "claude-haiku") == "Haiku")
        #expect(ClaudeProvider.prettyName(for: "claude-experimental-beta") == "Experimental Beta")
        #expect(ClaudeProvider.prettyName(for: "anthropic-other") == "Anthropic Other")
    }
}
