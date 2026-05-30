import Foundation
import Observation

@MainActor
@Observable
final class ConfigurationEditorViewModel {
    private(set) var profileID: UUID?
    private(set) var snapshotID: UUID?
    private(set) var title = ""
    private(set) var path = ""
    private(set) var fileKind: ProviderConfigFileKind = .text
    private(set) var draftContent = ""
    private(set) var draftCharacterCount = 0
    private(set) var diagnostics: [ConfigurationEditorDiagnostic] = []
    private(set) var isDirty = false
    private(set) var isWorking = false
    private(set) var lastSavedAt: Date?
    private(set) var cursorLine = 1
    private(set) var cursorColumn = 1

    @ObservationIgnored private let service: ConfigurationEditorService
    @ObservationIgnored private var savedContentHash = ConfigurationProfileStore.hash("")
    @ObservationIgnored private var savedContentByteCount = 0
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var diagnosticsGeneration = 0

    init(service: ConfigurationEditorService = ConfigurationEditorService()) {
        self.service = service
    }

    var isOpen: Bool {
        profileID != nil && snapshotID != nil
    }

    var hasDiagnostics: Bool {
        !diagnostics.isEmpty
    }

    var primaryDiagnostic: ConfigurationEditorDiagnostic? {
        diagnostics.first
    }

    func open(profile: ConfigProfile, snapshot: ConfigFileSnapshot?) {
        diagnosticsTask?.cancel()

        guard let snapshot else {
            clear()
            return
        }

        profileID = profile.id
        snapshotID = snapshot.id
        title = snapshot.title
        path = snapshot.path
        fileKind = snapshot.fileKind
        draftContent = snapshot.content
        draftCharacterCount = snapshot.content.count
        savedContentHash = snapshot.contentHash
        savedContentByteCount = snapshot.content.utf8.count
        isDirty = false
        diagnostics = []
        cursorLine = 1
        cursorColumn = 1
        scheduleDiagnostics(delayNanoseconds: 0)
    }

    func syncIfClean(profile: ConfigProfile, snapshot: ConfigFileSnapshot?) {
        guard !isDirty else { return }
        open(profile: profile, snapshot: snapshot)
    }

    func clear() {
        diagnosticsTask?.cancel()
        profileID = nil
        snapshotID = nil
        title = ""
        path = ""
        fileKind = .text
        draftContent = ""
        draftCharacterCount = 0
        savedContentHash = ConfigurationProfileStore.hash("")
        savedContentByteCount = 0
        isDirty = false
        diagnostics = []
        cursorLine = 1
        cursorColumn = 1
        lastSavedAt = nil
        diagnosticsGeneration &+= 1
    }

    func updateDraft(_ content: String) {
        guard draftContent != content else { return }
        draftContent = content
        draftCharacterCount = content.count
        updateDirtyState(for: content)
        scheduleDiagnostics()
    }

    func revert(profile: ConfigProfile, snapshot: ConfigFileSnapshot?) {
        open(profile: profile, snapshot: snapshot)
    }

    func markSaved(profile: ConfigProfile, snapshot: ConfigFileSnapshot, savedAt: Date = .now) {
        open(profile: profile, snapshot: snapshot)
        lastSavedAt = savedAt
    }

    func updateCursor(line: Int, column: Int) {
        let nextLine = max(1, line)
        let nextColumn = max(1, column)
        guard nextLine != cursorLine || nextColumn != cursorColumn else { return }
        cursorLine = nextLine
        cursorColumn = nextColumn
    }

    func setWorking(_ working: Bool) {
        isWorking = working
    }

    private func updateDirtyState(for content: String) {
        if content.utf8.count != savedContentByteCount {
            isDirty = true
        } else {
            isDirty = ConfigurationProfileStore.hash(content) != savedContentHash
        }
    }

    private func scheduleDiagnostics(delayNanoseconds: UInt64 = 180_000_000) {
        diagnosticsTask?.cancel()
        diagnosticsGeneration &+= 1
        let generation = diagnosticsGeneration
        let content = draftContent
        let kind = fileKind
        diagnosticsTask = Task { [weak self, service] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            let updated = await service.diagnostics(for: content, kind: kind)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.diagnosticsGeneration == generation else { return }
                self.diagnostics = updated
            }
        }
    }
}
