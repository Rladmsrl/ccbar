import Foundation

enum ProviderConfigFileKind: String, Codable, CaseIterable, Sendable, Hashable {
    case json
    case markdown
    case toml
    case text

    var displayName: String {
        switch self {
        case .json: "JSON"
        case .markdown: "Markdown"
        case .toml: "TOML"
        case .text: "Text"
        }
    }
}

enum ConfigProfileScope: Codable, Sendable, Hashable, Identifiable {
    case global
    case project(path: String)

    var id: String {
        switch self {
        case .global:
            "global"
        case .project(let path):
            "project:\(path)"
        }
    }

    var displayName: String {
        switch self {
        case .global:
            "Global"
        case .project(let path):
            URL(fileURLWithPath: path).lastPathComponent
        }
    }

    var detail: String {
        switch self {
        case .global:
            "Global CLI files"
        case .project(let path):
            path
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
    }

    private enum Kind: String, Codable {
        case global
        case project
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .project:
            self = .project(path: try container.decode(String.self, forKey: .path))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case .project(let path):
            try container.encode(Kind.project, forKey: .kind)
            try container.encode(path, forKey: .path)
        }
    }
}

struct ProviderConfigLocation: Identifiable, Sendable, Hashable {
    let provider: ProviderKind
    let title: String
    let url: URL
    let fileKind: ProviderConfigFileKind
    let isRequired: Bool

    var id: String { url.path }
    var path: String { url.path }

    init(provider: ProviderKind, title: String, url: URL, fileKind: ProviderConfigFileKind, isRequired: Bool = false) {
        self.provider = provider
        self.title = title
        self.url = url
        self.fileKind = fileKind
        self.isRequired = isRequired
    }
}
