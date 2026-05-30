import Foundation

struct ConfigFileSnapshot: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    var title: String
    var path: String
    var fileKind: ProviderConfigFileKind
    var content: String
    var contentHash: String
    var capturedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        path: String,
        fileKind: ProviderConfigFileKind,
        content: String,
        contentHash: String,
        capturedAt: Date = .now
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.fileKind = fileKind
        self.content = content
        self.contentHash = contentHash
        self.capturedAt = capturedAt
    }
}
