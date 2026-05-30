import Foundation
import Observation

@MainActor
@Observable
final class AIConfigsViewModel {
    private(set) var snapshot: AIConfigSnapshot = .empty
    private(set) var isLoading = false
    private(set) var lastError: String?

    @ObservationIgnored private let scanner: AIConfigScanner
    @ObservationIgnored private var hasLoaded = false

    init(scanner: AIConfigScanner) {
        self.scanner = scanner
    }

    func loadIfNeeded(sessions: [Session]) async {
        guard !hasLoaded else { return }
        await reload(sessions: sessions)
    }

    func reload(sessions: [Session]) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        snapshot = await scanner.scan(sessions: sessions)
        hasLoaded = true
        lastError = nil
    }

    func project(id: String?) -> AIConfigProject? {
        guard let id else { return nil }
        return snapshot.projects.first { $0.id == id }
    }

    func document(id: String?) -> AIConfigDocument? {
        guard let id else { return nil }
        return snapshot.projects.flatMap(\.documents).first { $0.id == id }
    }

    func filteredProjects(filter: AIConfigsFilter, query: String) -> [AIConfigProject] {
        let normalizedQuery = normalizedQuery(query)
        return snapshot.projects.compactMap { project in
            let documents = filteredDocuments(
                in: project,
                filter: filter,
                normalizedQuery: normalizedQuery
            )
            guard !documents.isEmpty else { return nil }
            return AIConfigProject(kind: project.kind, name: project.name, path: project.path, documents: documents)
        }
    }

    func filteredProjects(section: AIConfigsSection, query: String) -> [AIConfigProject] {
        let normalizedQuery = normalizedQuery(query)
        return snapshot.projects.compactMap { project in
            let documents = filteredDocuments(
                in: project,
                section: section,
                normalizedQuery: normalizedQuery
            )
            guard !documents.isEmpty else { return nil }
            return AIConfigProject(kind: project.kind, name: project.name, path: project.path, documents: documents)
        }
    }

    func documents(in project: AIConfigProject?, filter: AIConfigsFilter, query: String) -> [AIConfigDocument] {
        guard let project else { return [] }
        return filteredDocuments(in: project, filter: filter, normalizedQuery: normalizedQuery(query))
    }

    func documents(in project: AIConfigProject?, section: AIConfigsSection, query: String) -> [AIConfigDocument] {
        guard let project else { return [] }
        return filteredDocuments(in: project, section: section, normalizedQuery: normalizedQuery(query))
    }

    func resolvedProjectID(current: String?, filter: AIConfigsFilter, query: String) -> String? {
        let projects = filteredProjects(filter: filter, query: query)
        if let current, projects.contains(where: { $0.id == current }) {
            return current
        }
        return projects.first?.id
    }

    func resolvedProjectID(current: String?, section: AIConfigsSection, query: String) -> String? {
        let projects = filteredProjects(section: section, query: query)
        if let current, projects.contains(where: { $0.id == current }) {
            return current
        }
        return projects.first?.id
    }

    func resolvedDocumentID(current: String?, projectID: String?, filter: AIConfigsFilter, query: String) -> String? {
        let project = filteredProjects(filter: filter, query: query).first { $0.id == projectID }
        let documents = documents(in: project, filter: filter, query: query)
        if let current, documents.contains(where: { $0.id == current }) {
            return current
        }
        return documents.first?.id
    }

    func resolvedDocumentID(current: String?, projectID: String?, section: AIConfigsSection, query: String) -> String? {
        let project = filteredProjects(section: section, query: query).first { $0.id == projectID }
        let documents = documents(in: project, section: section, query: query)
        if let current, documents.contains(where: { $0.id == current }) {
            return current
        }
        return documents.first?.id
    }

    func count(for section: AIConfigsSection, query: String = "") -> Int {
        let documents = filteredProjects(section: section, query: query).flatMap(\.documents)
        switch section {
        case .overview:
            return documents.count
        case .diagnostics:
            return documents.reduce(0) { $0 + $1.diagnostics.count }
        case .instructions, .provider, .plans, .plugins:
            return documents.count
        }
    }

    private func filteredDocuments(
        in project: AIConfigProject,
        filter: AIConfigsFilter,
        normalizedQuery: String
    ) -> [AIConfigDocument] {
        project.documents.filter { document in
            guard filter.matches(document.kind) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return matches(query: normalizedQuery, project: project, document: document)
        }
    }

    private func filteredDocuments(
        in project: AIConfigProject,
        section: AIConfigsSection,
        normalizedQuery: String
    ) -> [AIConfigDocument] {
        project.documents.filter { document in
            guard sectionMatches(section, document: document) else { return false }
            guard !normalizedQuery.isEmpty else { return true }
            return matches(query: normalizedQuery, project: project, document: document)
        }
    }

    private func sectionMatches(_ section: AIConfigsSection, document: AIConfigDocument) -> Bool {
        switch section {
        case .overview:
            true
        case .diagnostics:
            !document.diagnostics.isEmpty
        case .instructions, .provider, .plans, .plugins:
            document.kind == section.documentKind
        }
    }

    private func matches(query: String, project: AIConfigProject, document: AIConfigDocument) -> Bool {
        project.name.lowercased().contains(query)
            || (project.path?.lowercased().contains(query) ?? false)
            || document.title.lowercased().contains(query)
            || document.path.lowercased().contains(query)
            || document.provider.shortName.lowercased().contains(query)
            || document.kind.displayName.lowercased().contains(query)
            || document.diagnostics.contains { $0.message.lowercased().contains(query) }
    }

    private func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
