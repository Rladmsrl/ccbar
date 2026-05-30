import Foundation
import Observation

@MainActor
@Observable
final class APIProviderSwitcherViewModel {
    private let store: ConfigurationProviderStore
    private var isOpeningDraft = false
    @ObservationIgnored private var sortedProvidersByCLI: [APIProviderCLI: [CLIAPIProvider]] = [:]

    private(set) var library = ConfigurationProviderLibrary() {
        didSet { sortedProvidersByCLI.removeAll() }
    }
    private(set) var isLoaded = false
    private(set) var isWorking = false
    private(set) var lastError: String?
    private(set) var latestApplyResult: ConfigurationProviderApplyResult?

    var selectedCLI: APIProviderCLI = .claude
    var selectedProviderID: String?

    var draftProviderID: String?
    var draftCLI: APIProviderCLI = .claude
    var draftOrigin: APIProviderOrigin?
    var draftName = "" { didSet { markDraftDirty(oldValue, draftName) } }
    var draftCategory: APIProviderCategory = .custom { didSet { markDraftDirty(oldValue, draftCategory) } }
    var draftBaseURL = "" { didSet { markDraftDirty(oldValue, draftBaseURL) } }
    var draftAPIKey = "" { didSet { markDraftDirty(oldValue, draftAPIKey) } }
    var draftModel = "" { didSet { markDraftDirty(oldValue, draftModel) } }
    var draftRawConfig = "" { didSet { markDraftDirty(oldValue, draftRawConfig) } }
    var draftIsDirty = false

    init(store: ConfigurationProviderStore = ConfigurationProviderStore()) {
        self.store = store
    }

    func loadIfNeeded(keyStorageMode: APIProviderKeyStorageMode) async {
        guard !isLoaded else {
            normalizeSelection(keyStorageMode: keyStorageMode)
            return
        }
        await reload(keyStorageMode: keyStorageMode)
    }

    func reload(keyStorageMode: APIProviderKeyStorageMode) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let loaded = try await store.loadLibrary()
            let ensured = try await store.ensureSystemProviders(in: loaded, keyStorageMode: keyStorageMode)
            library = ensured
            if ensured != loaded {
                try await store.saveLibrary(ensured)
            }
            isLoaded = true
            normalizeSelection(keyStorageMode: keyStorageMode)
        } catch {
            setError(error)
        }
    }

    func providers(for cli: APIProviderCLI) -> [CLIAPIProvider] {
        if let cached = sortedProvidersByCLI[cli] {
            return cached
        }

        let providers = library.cliProviders
            .filter { $0.cli == cli }
            .sorted { lhs, rhs in
                let lhsRank = Self.sortRank(lhs)
                let rhsRank = Self.sortRank(rhs)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        sortedProvidersByCLI[cli] = providers
        return providers
    }

    func activeProvider(for cli: APIProviderCLI) -> CLIAPIProvider? {
        guard let id = library.activeProviderIDs[cli] else { return nil }
        return provider(cli: cli, id: id)
    }

    func isActive(_ provider: CLIAPIProvider) -> Bool {
        library.activeProviderIDs[provider.cli] == provider.id
    }

    var selectedProvider: CLIAPIProvider? {
        guard let selectedProviderID else { return nil }
        return provider(cli: selectedCLI, id: selectedProviderID)
    }

    var canSaveSelectedProvider: Bool {
        draftOrigin?.kind != .official && draftProviderID != nil
    }

    var canDeleteSelectedProvider: Bool {
        guard let provider = selectedProvider else { return false }
        return !provider.isSystemProvider && !isActive(provider)
    }

    func selectCLI(_ cli: APIProviderCLI, keyStorageMode: APIProviderKeyStorageMode) {
        selectedCLI = cli
        selectedProviderID = nil
        normalizeSelection(keyStorageMode: keyStorageMode)
    }

    func selectProvider(_ provider: CLIAPIProvider, keyStorageMode: APIProviderKeyStorageMode) {
        selectedCLI = provider.cli
        selectedProviderID = provider.id
        openDraft(provider, keyStorageMode: keyStorageMode)
    }

    func addProvider(keyStorageMode: APIProviderKeyStorageMode) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let provider = store.makeCustomProvider(cli: selectedCLI, keyStorageMode: keyStorageMode)
            library.cliProviders.append(provider)
            try await store.saveLibrary(library)
            selectedProviderID = provider.id
            openDraft(provider, keyStorageMode: keyStorageMode)
        } catch {
            setError(error)
        }
    }

    func addUniversalProvider(keyStorageMode: APIProviderKeyStorageMode) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let (universal, children) = store.makeUniversalProvider(keyStorageMode: keyStorageMode)
            library.universalProviders.append(universal)
            library.cliProviders.append(contentsOf: children)
            try await store.saveLibrary(library)
            let selectedID = ConfigurationProviderStore.universalChildID(universalID: universal.id, cli: selectedCLI)
            selectedProviderID = selectedID
            if let provider = provider(cli: selectedCLI, id: selectedID) {
                openDraft(provider, keyStorageMode: keyStorageMode)
            }
        } catch {
            setError(error)
        }
    }

    func importCurrent(keyStorageMode: APIProviderKeyStorageMode) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let imported = try await store.importCurrentProvider(
                cli: selectedCLI,
                name: "Default",
                id: "default",
                keyStorageMode: keyStorageMode
            )
            replaceCLIProvider(imported)
            library.activeProviderIDs[selectedCLI] = imported.id
            try await store.saveLibrary(library)
            selectedProviderID = imported.id
            openDraft(imported, keyStorageMode: keyStorageMode)
        } catch {
            setError(error)
        }
    }

    @discardableResult
    func saveDraft(rawMode: Bool, keyStorageMode: APIProviderKeyStorageMode) async -> Bool {
        isWorking = true
        defer { isWorking = false }
        do {
            let saved = try await saveDraftThrowing(rawMode: rawMode, keyStorageMode: keyStorageMode)
            selectedProviderID = saved.id
            openDraft(saved, keyStorageMode: keyStorageMode)
            return true
        } catch {
            setError(error)
            return false
        }
    }

    func enableSelectedProvider(rawMode: Bool, keyStorageMode: APIProviderKeyStorageMode) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let target: CLIAPIProvider
            if draftIsDirty {
                target = try await saveDraftThrowing(rawMode: rawMode, keyStorageMode: keyStorageMode)
            } else {
                guard let selectedProvider else { throw ConfigurationProviderStoreError.providerNotFound }
                target = selectedProvider
            }

            let current = activeProvider(for: target.cli)
            let (result, backfilled) = try await store.apply(
                provider: target,
                currentActive: current,
                keyStorageMode: keyStorageMode
            )
            if let backfilled {
                replaceCLIProvider(backfilled)
            }
            library.activeProviderIDs[target.cli] = target.id
            latestApplyResult = result
            try await store.saveLibrary(library)
            selectedProviderID = target.id
            openDraft(target, keyStorageMode: keyStorageMode)
        } catch {
            setError(error)
        }
    }

    func deleteSelectedProvider(keyStorageMode: APIProviderKeyStorageMode) async {
        guard canDeleteSelectedProvider, let provider = selectedProvider else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let removedSecrets: [APIProviderSecret]
            if provider.origin.kind == .universal, let universalID = provider.origin.universalID {
                let removedUniversals = library.universalProviders.filter { $0.id == universalID }
                let removedChildren = library.cliProviders.filter { $0.origin.kind == .universal && $0.origin.universalID == universalID }
                removedSecrets = removedUniversals.map(\.apiKey) + removedChildren.map(\.apiKey)
                library.universalProviders.removeAll { $0.id == universalID }
                library.cliProviders.removeAll { $0.origin.kind == .universal && $0.origin.universalID == universalID }
            } else {
                let removedProviders = library.cliProviders.filter { $0.cli == provider.cli && $0.id == provider.id }
                removedSecrets = removedProviders.map(\.apiKey)
                library.cliProviders.removeAll { $0.cli == provider.cli && $0.id == provider.id }
            }
            try await store.saveLibrary(library)
            store.deleteStoredSecrets(removedSecrets, retainedIn: library)
            selectedProviderID = nil
            normalizeSelection(keyStorageMode: keyStorageMode)
        } catch {
            setError(error)
        }
    }

    func resetDraft(keyStorageMode: APIProviderKeyStorageMode) {
        guard let selectedProvider else {
            clearDraft()
            return
        }
        openDraft(selectedProvider, keyStorageMode: keyStorageMode)
    }

    func clearError() {
        lastError = nil
    }

    private func saveDraftThrowing(rawMode: Bool, keyStorageMode: APIProviderKeyStorageMode) async throws -> CLIAPIProvider {
        guard let draftProviderID,
              let existing = provider(cli: draftCLI, id: draftProviderID) else {
            throw ConfigurationProviderStoreError.providerNotFound
        }

        let saved: CLIAPIProvider
        var replacedSecrets: [APIProviderSecret] = []
        if existing.origin.kind == .universal, let universalID = existing.origin.universalID {
            guard let universalIndex = library.universalProviders.firstIndex(where: { $0.id == universalID }) else {
                throw ConfigurationProviderStoreError.providerNotFound
            }
            replacedSecrets.append(library.universalProviders[universalIndex].apiKey)
            let updatedUniversal = try store.universalBySavingDraft(
                existing: library.universalProviders[universalIndex],
                editedCLI: draftCLI,
                name: draftName,
                baseURL: draftBaseURL,
                apiKey: draftAPIKey,
                model: draftModel,
                keyStorageMode: keyStorageMode
            )
            library.universalProviders[universalIndex] = updatedUniversal
            let removedChildren = library.cliProviders.filter { $0.origin.kind == .universal && $0.origin.universalID == universalID }
            replacedSecrets.append(contentsOf: removedChildren.map(\.apiKey))
            library.cliProviders.removeAll { $0.origin.kind == .universal && $0.origin.universalID == universalID }
            library.cliProviders.append(contentsOf: store.childProviders(for: updatedUniversal, keyStorageMode: keyStorageMode))
            let childID = ConfigurationProviderStore.universalChildID(universalID: universalID, cli: draftCLI)
            guard let child = provider(cli: draftCLI, id: childID) else {
                throw ConfigurationProviderStoreError.providerNotFound
            }
            saved = child
        } else {
            let updated = try store.providerBySavingDraft(
                existing: existing,
                name: draftName,
                category: draftCategory,
                baseURL: draftBaseURL,
                apiKey: draftAPIKey,
                model: draftModel,
                rawConfig: draftRawConfig,
                rawMode: rawMode,
                keyStorageMode: keyStorageMode
            )
            replacedSecrets.append(existing.apiKey)
            replaceCLIProvider(updated)
            saved = updated
        }

        try await store.saveLibrary(library)
        store.deleteStoredSecrets(replacedSecrets, retainedIn: library)
        draftIsDirty = false
        return saved
    }

    private func normalizeSelection(keyStorageMode: APIProviderKeyStorageMode) {
        let available = providers(for: selectedCLI)
        if let selectedProviderID,
           available.contains(where: { $0.id == selectedProviderID }) {
            if let provider = provider(cli: selectedCLI, id: selectedProviderID) {
                openDraft(provider, keyStorageMode: keyStorageMode)
            }
            return
        }

        let preferredID = library.activeProviderIDs[selectedCLI] ?? available.first?.id
        selectedProviderID = preferredID
        if let preferredID, let provider = provider(cli: selectedCLI, id: preferredID) {
            openDraft(provider, keyStorageMode: keyStorageMode)
        } else {
            clearDraft()
        }
    }

    private func openDraft(_ provider: CLIAPIProvider, keyStorageMode _: APIProviderKeyStorageMode) {
        isOpeningDraft = true
        draftProviderID = provider.id
        draftCLI = provider.cli
        draftOrigin = provider.origin
        draftName = provider.name
        draftCategory = provider.category
        draftBaseURL = provider.baseURL
        draftAPIKey = store.resolvedAPIKey(for: provider.apiKey)
        draftModel = provider.model
        draftRawConfig = store.renderRawConfig(for: provider)
        draftIsDirty = false
        isOpeningDraft = false
    }

    private func clearDraft() {
        isOpeningDraft = true
        draftProviderID = nil
        draftOrigin = nil
        draftName = ""
        draftCategory = .custom
        draftBaseURL = ""
        draftAPIKey = ""
        draftModel = ""
        draftRawConfig = ""
        draftIsDirty = false
        isOpeningDraft = false
    }

    private func provider(cli: APIProviderCLI, id: String) -> CLIAPIProvider? {
        library.cliProviders.first { $0.cli == cli && $0.id == id }
    }

    private func replaceCLIProvider(_ provider: CLIAPIProvider) {
        if let index = library.cliProviders.firstIndex(where: { $0.cli == provider.cli && $0.id == provider.id }) {
            library.cliProviders[index] = provider
        } else {
            library.cliProviders.append(provider)
        }
    }

    private func markDraftDirty<T: Equatable>(_ oldValue: T, _ newValue: T) {
        guard !isOpeningDraft, oldValue != newValue else { return }
        draftIsDirty = true
    }

    private func setError(_ error: Error) {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            lastError = description
        } else {
            lastError = error.localizedDescription
        }
    }

    private static func sortRank(_ provider: CLIAPIProvider) -> Int {
        switch provider.origin.kind {
        case .official: 0
        case .importedDefault: 1
        case .universal: 2
        case .appSpecific: 3
        }
    }
}
