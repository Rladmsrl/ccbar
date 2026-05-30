import Foundation
import Observation

@MainActor
@Observable
final class CLIEnvironmentViewModel {
    private let checker: any CLIEnvironmentChecking

    private(set) var statuses: [APIProviderCLI: CLIToolStatus] = [:]
    private(set) var conflicts: [CLIEnvironmentConflict] = []
    private(set) var isLoaded = false
    private(set) var isLoading = false
    private(set) var isCleaning = false
    private(set) var lastError: String?
    private(set) var latestCleanupResult: CLIEnvironmentCleanupResult?

    private var selectedConflictIDs = Set<String>()
    private var revealedConflictIDs = Set<String>()

    init(checker: any CLIEnvironmentChecking = CLIEnvironmentChecker()) {
        self.checker = checker
    }

    func loadIfNeeded() async {
        guard !isLoaded else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await checker.checkAll()
            statuses = Dictionary(uniqueKeysWithValues: snapshot.statuses.map { ($0.cli, $0) })
            conflicts = snapshot.conflicts
            selectedConflictIDs.formIntersection(Set(snapshot.conflicts.map(\.id)))
            revealedConflictIDs.formIntersection(Set(snapshot.conflicts.map(\.id)))
            isLoaded = true
            lastError = nil
        } catch {
            setError(error)
        }
    }

    func status(for cli: APIProviderCLI) -> CLIToolStatus? {
        statuses[cli]
    }

    var selectedDeletableCount: Int {
        selectedDeletableConflicts.count
    }

    var hasConflicts: Bool {
        !conflicts.isEmpty
    }

    func isSelected(_ conflict: CLIEnvironmentConflict) -> Bool {
        selectedConflictIDs.contains(conflict.id)
    }

    func toggleSelection(_ conflict: CLIEnvironmentConflict) {
        guard conflict.isDeletable else { return }
        if selectedConflictIDs.contains(conflict.id) {
            selectedConflictIDs.remove(conflict.id)
        } else {
            selectedConflictIDs.insert(conflict.id)
        }
    }

    func selectAllDeletableConflicts() {
        selectedConflictIDs = Set(conflicts.filter(\.isDeletable).map(\.id))
    }

    func clearSelection() {
        selectedConflictIDs.removeAll()
    }

    func isRevealed(_ conflict: CLIEnvironmentConflict) -> Bool {
        revealedConflictIDs.contains(conflict.id)
    }

    func toggleReveal(_ conflict: CLIEnvironmentConflict) {
        if revealedConflictIDs.contains(conflict.id) {
            revealedConflictIDs.remove(conflict.id)
        } else {
            revealedConflictIDs.insert(conflict.id)
        }
    }

    func deleteSelectedConflicts() async {
        let targets = selectedDeletableConflicts
        guard !targets.isEmpty else { return }
        isCleaning = true
        defer { isCleaning = false }
        do {
            let result = try await checker.deleteConflicts(targets)
            latestCleanupResult = result
            selectedConflictIDs.subtract(result.deletedConflictIDs)
            await refresh()
            if !result.skippedConflicts.isEmpty {
                latestCleanupResult = result
            }
        } catch {
            setError(error)
        }
    }

    func clearError() {
        lastError = nil
    }

    private var selectedDeletableConflicts: [CLIEnvironmentConflict] {
        conflicts.filter { $0.isDeletable && selectedConflictIDs.contains($0.id) }
    }

    private func setError(_ error: Error) {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            lastError = description
        } else {
            lastError = error.localizedDescription
        }
    }
}
