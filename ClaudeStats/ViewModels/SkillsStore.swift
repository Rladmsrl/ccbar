import Foundation
import Observation

@MainActor
@Observable
final class SkillsStore {
    var selectedTab: SkillsWorkspaceTab = .installed
    var selectedDetailTab: SkillsDetailTab = .overview
    var localSearchText = "" {
        didSet { rebuildDerivedState() }
    }
    var discoverSearchText = ""
    var curatedSearchText = "" {
        didSet { rebuildDerivedState(resolvingRemoteSelection: true) }
    }
    var searchText: String {
        get {
            switch selectedTab {
            case .installed: localSearchText
            case .discover: discoverSearchText
            case .curated: curatedSearchText
            }
        }
        set {
            switch selectedTab {
            case .installed:
                localSearchText = newValue
            case .discover:
                discoverSearchText = newValue
            case .curated:
                curatedSearchText = newValue
            }
        }
    }
    var selectedProviderID: String? {
        didSet { rebuildDerivedState() }
    }
    var scopeFilter: SkillScopeFilter = .all {
        didSet { rebuildDerivedState() }
    }
    private(set) var selectedLocalGroupID: String?
    private(set) var selectedRemoteSkillID: String?
    var apiKeyDraft = ""

    private(set) var snapshot: SkillsSnapshot = .empty
    private(set) var isScanning = false
    private(set) var isRemoteLoading = false
    private(set) var isLocalMarkdownLoading = false
    private(set) var lastError: String?
    private(set) var remoteError: String?
    private(set) var hasAPIKey = false
    private(set) var remoteResults: [RemoteSkillSummary] = []
    private(set) var curatedOwners: [SkillsShCuratedOwner] = []
    private(set) var remoteDetails: [String: SkillRemoteDetailBundle] = [:]
    private(set) var headerSummaryText = ""
    private(set) var visibleLocalGroups: [LocalSkillGroup] = []
    private(set) var visibleLocalRows: [LocalSkillRowModel] = []
    private(set) var groupsByID: [String: LocalSkillGroup] = [:]
    private(set) var discoverRows: [RemoteSkillRowModel] = []
    private(set) var curatedOwnerRows: [CuratedSkillOwnerRowModel] = []
    private(set) var remoteSkillsByID: [String: RemoteSkillSummary] = [:]
    private(set) var selectedLocalDetailModel: LocalSkillDetailModel?
    private(set) var selectedRemoteDetailModel: RemoteSkillDetailModel?
    private(set) var selectedLocalMarkdownDocument: SkillMarkdownDocument?

    @ObservationIgnored private let scanner: any SkillsLocalScanning
    @ObservationIgnored private let client: any SkillsShClienting
    @ObservationIgnored private let credentials: any SkillsShCredentialStoring
    @ObservationIgnored private var hasLoadedLocal = false
    @ObservationIgnored private var cachedAPIKey: String?
    @ObservationIgnored private var lastProjectRootSignature: String?
    @ObservationIgnored private var pendingLocalReload: PendingLocalReload?
    @ObservationIgnored private var localFullHashTask: Task<Void, Never>?
    @ObservationIgnored private var hasFullLocalHashes = false
    @ObservationIgnored private var installedHashes: Set<String> = []
    @ObservationIgnored private var localGroupIDs: Set<String> = []

    init(
        scanner: any SkillsLocalScanning = SkillsLocalScanner(),
        client: any SkillsShClienting = SkillsShClient(),
        credentials: any SkillsShCredentialStoring = SkillsShKeychainStore.shared
    ) {
        self.scanner = scanner
        self.client = client
        self.credentials = credentials
        let key = credentials.readAPIKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
        cachedAPIKey = key?.isEmpty == false ? key : nil
        hasAPIKey = cachedAPIKey != nil
        headerSummaryText = Self.headerSummaryText(for: snapshot)
    }

    deinit {
        localFullHashTask?.cancel()
    }

    var filteredLocalGroups: [LocalSkillGroup] {
        visibleLocalGroups
    }

    var selectedLocalGroup: LocalSkillGroup? {
        guard let selectedLocalGroupID else { return nil }
        return groupsByID[selectedLocalGroupID]
    }

    var remoteDisplayResults: [RemoteSkillSummary] {
        switch selectedTab {
        case .installed:
            []
        case .discover:
            discoverRows.map(\.skill)
        case .curated:
            curatedOwnerRows.flatMap { owner in owner.skills.map(\.skill) }
        }
    }

    var selectedRemoteSkill: RemoteSkillSummary? {
        guard let selectedRemoteSkillID else { return nil }
        return remoteSkillsByID[selectedRemoteSkillID]
    }

    var selectedLocalDetail: LocalSkillDetailModel? {
        selectedLocalDetailModel
    }

    var selectedRemoteDetail: RemoteSkillDetailModel? {
        selectedRemoteDetailModel
    }

    func loadIfNeeded(sessions: [Session]) async {
        guard !hasLoadedLocal else { return }
        await reloadLocal(sessions: sessions)
    }

    func reloadLocal(sessions: [Session]) async {
        let signature = await Self.projectRootSignature(sessions)
        if isScanning {
            pendingLocalReload = PendingLocalReload(sessions: sessions, signature: signature)
            return
        }
        await performLocalIndexReload(sessions: sessions, signature: signature)
    }

    func reloadLocalIfProjectRootsChanged(sessions: [Session]) async {
        let signature = await Self.projectRootSignature(sessions)
        guard signature != lastProjectRootSignature else { return }
        if isScanning {
            pendingLocalReload = PendingLocalReload(sessions: sessions, signature: signature)
            return
        }
        await performLocalIndexReload(sessions: sessions, signature: signature)
    }

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try credentials.saveAPIKey(trimmed)
            cachedAPIKey = trimmed
            hasAPIKey = true
            apiKeyDraft = ""
            remoteError = nil
        } catch {
            remoteError = "Could not save skills.sh API key: \(error.localizedDescription)"
        }
    }

    func deleteAPIKey() {
        credentials.deleteAPIKey()
        cachedAPIKey = nil
        hasAPIKey = false
        apiKeyDraft = ""
        remoteResults = []
        curatedOwners = []
        remoteDetails = [:]
        remoteError = nil
        selectedRemoteSkillID = nil
        rebuildDerivedState()
    }

    func refreshRemote() async {
        switch selectedTab {
        case .installed:
            return
        case .discover:
            await searchOrLoadTrending()
        case .curated:
            await loadCurated()
        }
    }

    func searchOrLoadTrending() async {
        guard let apiKey = apiKey() else {
            rebuildDerivedState()
            return
        }
        guard !isRemoteLoading else { return }
        setRemoteLoading(true)
        defer { setRemoteLoading(false) }

        do {
            let query = discoverSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if query.count >= 2 {
                remoteResults = try await client.search(query: query, apiKey: apiKey, limit: 75)
            } else {
                remoteResults = try await client.leaderboard(apiKey: apiKey, view: "trending", limit: 100)
            }
            remoteError = nil
            rebuildDerivedState(resolvingRemoteSelection: true)
        } catch {
            remoteError = errorDescription(error)
            rebuildDerivedState()
        }
    }

    func loadCurated() async {
        guard let apiKey = apiKey() else {
            rebuildDerivedState()
            return
        }
        guard !isRemoteLoading else { return }
        setRemoteLoading(true)
        defer { setRemoteLoading(false) }

        do {
            curatedOwners = try await client.curated(apiKey: apiKey)
            remoteError = nil
            rebuildDerivedState(resolvingRemoteSelection: true)
        } catch {
            remoteError = errorDescription(error)
            rebuildDerivedState()
        }
    }

    func loadRemoteDetail(id: String) async {
        guard remoteDetails[id]?.detail == nil || remoteDetails[id]?.audit == nil else { return }
        guard let apiKey = apiKey() else {
            rebuildDerivedState()
            return
        }

        do {
            async let detail = client.detail(id: id, apiKey: apiKey)
            async let audit = client.audit(id: id, apiKey: apiKey)
            remoteDetails[id] = SkillRemoteDetailBundle(
                detail: try await detail,
                audit: try await audit
            )
            remoteError = nil
            rebuildDerivedState()
        } catch {
            remoteError = errorDescription(error)
            rebuildDerivedState()
        }
    }

    func loadSelectedLocalMarkdownDocument() async {
        guard let selectedLocalGroup, let skill = selectedLocalGroup.primarySkill else {
            selectedLocalMarkdownDocument = nil
            return
        }

        let documentID = "local:\(skill.id)"
        if selectedLocalMarkdownDocument?.id == documentID {
            return
        }

        let skillID = skill.id
        let groupID = selectedLocalGroup.id
        let path = skill.skillMarkdownPath
        let contentHash = skill.contentHash
        isLocalMarkdownLoading = true
        let text = await Task.detached(priority: .userInitiated) {
            try? String(contentsOfFile: path, encoding: .utf8)
        }.value
        guard selectedLocalGroupID == groupID,
              groupsByID[groupID]?.primarySkill?.id == skillID else {
            isLocalMarkdownLoading = false
            return
        }
        selectedLocalMarkdownDocument = text.map {
            SkillMarkdownDocument(id: documentID, contentHash: contentHash, text: $0)
        }
        isLocalMarkdownLoading = false
    }

    func selectLocalGroup(id: String) {
        selectedLocalGroupID = id
        selectedDetailTab = .overview
        selectedLocalMarkdownDocument = nil
        rebuildDerivedState()
    }

    func selectLocalGroup(_ group: LocalSkillGroup) {
        selectLocalGroup(id: group.id)
    }

    func selectRemoteSkill(_ skill: RemoteSkillSummary) {
        selectedRemoteSkillID = skill.id
        selectedDetailTab = .overview
        rebuildDerivedState()
    }

    func installState(for remote: RemoteSkillSummary) -> SkillInstallState {
        computedInstallState(for: remote)
    }

    func syncLocalSelection() {
        rebuildDerivedState()
    }

    func waitForLocalHashRefresh() async {
        await localFullHashTask?.value
    }

    private func performLocalIndexReload(sessions: [Session], signature: String) async {
        var nextSessions = sessions
        var nextSignature = signature
        isScanning = true

        while true {
            localFullHashTask?.cancel()
            hasFullLocalHashes = false
            lastProjectRootSignature = nextSignature

            let indexSnapshot = await scanner.scan(sessions: nextSessions, mode: .indexOnly)
            guard !Task.isCancelled else {
                isScanning = false
                return
            }

            apply(snapshot: indexSnapshot)
            hasLoadedLocal = true
            lastError = nil

            if let pendingLocalReload {
                self.pendingLocalReload = nil
                nextSessions = pendingLocalReload.sessions
                nextSignature = pendingLocalReload.signature
                continue
            }

            isScanning = false
            startFullHashRefresh(sessions: nextSessions, signature: nextSignature)
            return
        }
    }

    private func apply(snapshot nextSnapshot: SkillsSnapshot) {
        snapshot = nextSnapshot
        hasFullLocalHashes = nextSnapshot.scanMode == .fullHash
        installedHashes = Set(nextSnapshot.skills.compactMap(\.contentHash))
        rebuildDerivedState()
    }

    private func startFullHashRefresh(sessions: [Session], signature: String) {
        localFullHashTask?.cancel()
        let scanner = scanner
        localFullHashTask = Task.detached(priority: .utility) { [weak self] in
            let snapshot = await scanner.scan(sessions: sessions, mode: .fullHash)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.finishFullHashRefresh(snapshot: snapshot, signature: signature)
            }
        }
    }

    private func finishFullHashRefresh(snapshot fullHashSnapshot: SkillsSnapshot, signature: String) {
        guard signature == lastProjectRootSignature else { return }
        installedHashes = Set(fullHashSnapshot.skills.compactMap(\.contentHash))
        hasFullLocalHashes = true
        rebuildDerivedState()
    }

    private func setRemoteLoading(_ isLoading: Bool) {
        isRemoteLoading = isLoading
        rebuildDerivedState()
    }

    private func rebuildDerivedState(resolvingRemoteSelection: Bool = false) {
        let state = makeDerivedState(resolvingRemoteSelection: resolvingRemoteSelection)
        apply(derivedState: state)
    }

    private func makeDerivedState(resolvingRemoteSelection: Bool) -> SkillsDerivedState {
        let groupsByID = Dictionary(uniqueKeysWithValues: snapshot.groups.map { ($0.id, $0) })
        let normalizedQuery = normalized(localSearchText)
        let visibleLocalGroups = snapshot.groups.filter { group in
            let providerMatches = selectedProviderID.map { providerID in
                group.skills.contains { $0.providerID == providerID }
            } ?? true
            guard providerMatches else { return false }
            guard group.skills.contains(where: { scopeFilter.matches($0.scope) }) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return matches(group: group, query: normalizedQuery)
        }
        let visibleLocalRows = visibleLocalGroups.map(LocalSkillRowModel.init(group:))
        let nextSelectedLocalID: String?
        if let selectedLocalGroupID,
           visibleLocalGroups.contains(where: { $0.id == selectedLocalGroupID }) {
            nextSelectedLocalID = selectedLocalGroupID
        } else {
            nextSelectedLocalID = visibleLocalGroups.first?.id
        }
        let selectedLocalDetailModel = nextSelectedLocalID
            .flatMap { groupsByID[$0] }
            .map(LocalSkillDetailModel.init(group:))

        let discoverRows = remoteResults.map { skill in
            RemoteSkillRowModel(skill: skill, installState: computedInstallState(for: skill))
        }
        let curatedQuery = normalized(curatedSearchText)
        let curatedOwnerRows: [CuratedSkillOwnerRowModel] = curatedOwners.compactMap { owner -> CuratedSkillOwnerRowModel? in
            let skills = owner.skills
                .filter { skill in
                    guard !curatedQuery.isEmpty else { return true }
                    return remoteMatches(skill: skill, owner: owner.owner, query: curatedQuery)
                }
                .map { skill in
                    RemoteSkillRowModel(skill: skill, installState: computedInstallState(for: skill))
                }
            guard !skills.isEmpty || (curatedQuery.isEmpty && owner.skills.isEmpty) else { return nil }
            return CuratedSkillOwnerRowModel(
                owner: owner.owner,
                totalInstalls: owner.totalInstalls,
                skills: skills
            )
        }

        var remoteSkillsByID: [String: RemoteSkillSummary] = [:]
        for row in discoverRows {
            remoteSkillsByID[row.skill.id] = row.skill
        }
        for owner in curatedOwnerRows {
            for row in owner.skills {
                remoteSkillsByID[row.skill.id] = row.skill
            }
        }

        let nextSelectedRemoteID: String?
        if resolvingRemoteSelection {
            nextSelectedRemoteID = resolvedRemoteID(
                current: selectedRemoteSkillID,
                discoverRows: discoverRows,
                curatedOwnerRows: curatedOwnerRows
            )
        } else if let selectedRemoteSkillID,
                  remoteSkillsByID[selectedRemoteSkillID] != nil {
            nextSelectedRemoteID = selectedRemoteSkillID
        } else {
            nextSelectedRemoteID = nil
        }

        let selectedRemoteDetailModel = nextSelectedRemoteID
            .flatMap { remoteSkillsByID[$0] }
            .map { skill in
                RemoteSkillDetailModel(
                    skill: skill,
                    bundle: remoteDetails[skill.id],
                    installState: computedInstallState(for: skill),
                    isDetailLoading: isRemoteLoading
                )
            }

        return SkillsDerivedState(
            headerSummaryText: Self.headerSummaryText(for: snapshot),
            visibleLocalGroups: visibleLocalGroups,
            visibleLocalRows: visibleLocalRows,
            groupsByID: groupsByID,
            localGroupIDs: Set(snapshot.groups.map(\.id)),
            selectedLocalGroupID: nextSelectedLocalID,
            selectedLocalDetailModel: selectedLocalDetailModel,
            discoverRows: discoverRows,
            curatedOwnerRows: curatedOwnerRows,
            remoteSkillsByID: remoteSkillsByID,
            selectedRemoteSkillID: nextSelectedRemoteID,
            selectedRemoteDetailModel: selectedRemoteDetailModel
        )
    }

    private func apply(derivedState: SkillsDerivedState) {
        let previousLocalSelection = selectedLocalGroupID
        headerSummaryText = derivedState.headerSummaryText
        visibleLocalGroups = derivedState.visibleLocalGroups
        visibleLocalRows = derivedState.visibleLocalRows
        groupsByID = derivedState.groupsByID
        localGroupIDs = derivedState.localGroupIDs
        selectedLocalGroupID = derivedState.selectedLocalGroupID
        selectedLocalDetailModel = derivedState.selectedLocalDetailModel
        discoverRows = derivedState.discoverRows
        curatedOwnerRows = derivedState.curatedOwnerRows
        remoteSkillsByID = derivedState.remoteSkillsByID
        selectedRemoteSkillID = derivedState.selectedRemoteSkillID
        selectedRemoteDetailModel = derivedState.selectedRemoteDetailModel

        if previousLocalSelection != selectedLocalGroupID {
            selectedLocalMarkdownDocument = nil
        }
    }

    private func resolvedRemoteID(
        current: String?,
        discoverRows: [RemoteSkillRowModel],
        curatedOwnerRows: [CuratedSkillOwnerRowModel]
    ) -> String? {
        let results: [RemoteSkillSummary]
        switch selectedTab {
        case .installed:
            results = []
        case .discover:
            results = discoverRows.map(\.skill)
        case .curated:
            results = curatedOwnerRows.flatMap { owner in owner.skills.map(\.skill) }
        }
        if let current, results.contains(where: { $0.id == current }) {
            return current
        }
        return results.first?.id
    }

    private func apiKey() -> String? {
        guard let key = cachedAPIKey, !key.isEmpty else {
            hasAPIKey = false
            remoteError = SkillsShClient.ClientError.missingAPIKey.description
            return nil
        }
        hasAPIKey = true
        return key
    }

    private func matches(group: LocalSkillGroup, query: String) -> Bool {
        if group.name.lowercased().contains(query) { return true }
        if group.description?.lowercased().contains(query) == true { return true }
        return group.skills.contains { skill in
            skill.providerName.lowercased().contains(query)
                || skill.folderPath.lowercased().contains(query)
                || skill.plugin?.displayName.lowercased().contains(query) == true
                || skill.frontmatter.creator?.lowercased().contains(query) == true
        }
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func remoteMatches(skill: RemoteSkillSummary, owner: String, query: String) -> Bool {
        if owner.lowercased().contains(query) { return true }
        if skill.id.lowercased().contains(query) { return true }
        if skill.name.lowercased().contains(query) { return true }
        if skill.slug?.lowercased().contains(query) == true { return true }
        if skill.source?.lowercased().contains(query) == true { return true }
        if skill.sourceType?.lowercased().contains(query) == true { return true }
        return false
    }

    private func computedInstallState(for remote: RemoteSkillSummary) -> SkillInstallState {
        let bundle = remoteDetails[remote.id]
        if let hash = bundle?.detail?.hash, installedHashes.contains(hash) {
            return .installed
        }

        let candidates = [
            remote.slug,
            remote.name,
            remote.id.split(separator: "/").last.map(String.init),
        ]
        .compactMap { $0 }
        .map(LocalSkillItem.normalizedName)

        let nameMatches = candidates.contains { localGroupIDs.contains($0) }
        if nameMatches, bundle?.detail?.hash != nil {
            return hasFullLocalHashes ? .outOfDate : .possiblyInstalled
        }
        if nameMatches {
            return .possiblyInstalled
        }
        return .notInstalled
    }

    private nonisolated static func headerSummaryText(for snapshot: SkillsSnapshot) -> String {
        var items = [
            "\(snapshot.summary.groupCount) skills",
            "\(snapshot.summary.skillCount) copies",
            "\(snapshot.summary.providerCount) providers",
        ]
        if snapshot.summary.pluginSkillCount > 0 {
            items.append("\(snapshot.summary.pluginSkillCount) plugin skills")
        }
        if snapshot.summary.projectRootCount > 0 {
            items.append("\(snapshot.summary.projectRootCount) projects")
        }
        if let scannedAt = snapshot.scannedAt {
            items.append("Updated \(Format.relativeDate(scannedAt))")
        }
        return items.joined(separator: " . ")
    }

    private nonisolated static func projectRootSignature(_ sessions: [Session]) async -> String {
        await Task.detached(priority: .utility) {
            let roots = Set(
                sessions
                    .compactMap(\.cwd)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
            )
            return roots.sorted().joined(separator: "\n")
        }.value
    }

    private func errorDescription(_ error: Error) -> String {
        if let error = error as? SkillsShClient.ClientError {
            return error.description
        }
        return error.localizedDescription
    }
}

private struct PendingLocalReload {
    let sessions: [Session]
    let signature: String
}

private struct SkillsDerivedState {
    let headerSummaryText: String
    let visibleLocalGroups: [LocalSkillGroup]
    let visibleLocalRows: [LocalSkillRowModel]
    let groupsByID: [String: LocalSkillGroup]
    let localGroupIDs: Set<String>
    let selectedLocalGroupID: String?
    let selectedLocalDetailModel: LocalSkillDetailModel?
    let discoverRows: [RemoteSkillRowModel]
    let curatedOwnerRows: [CuratedSkillOwnerRowModel]
    let remoteSkillsByID: [String: RemoteSkillSummary]
    let selectedRemoteSkillID: String?
    let selectedRemoteDetailModel: RemoteSkillDetailModel?
}
