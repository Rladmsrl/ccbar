import SwiftUI

struct AIConfigsDetailView: View {
    let section: AIConfigsSection
    let searchText: String
    @Binding var selectedProjectID: String
    @Binding var selectedDocumentID: String

    @Environment(AppEnvironment.self) private var env
    private let horizontalInset: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            StxRule()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            await env.aiConfigs.loadIfNeeded(sessions: env.store.sessions)
            syncSelection()
        }
        .onChange(of: env.store.lastRefreshedAt) { _, _ in
            Task {
                await env.aiConfigs.reload(sessions: env.store.sessions)
                syncSelection()
            }
        }
        .onChange(of: section) { _, _ in syncSelection() }
        .onChange(of: searchText) { _, _ in syncSelection() }
        .onChange(of: env.aiConfigs.snapshot) { _, _ in syncSelection() }
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CONFIGS")
                    .font(.sora(11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.stxMuted)
                Text(LocalizedStringKey(section.detailTitle))
                    .font(.sora(24, weight: .semibold))
                    .lineLimit(1)
                Text(LocalizedStringKey(section.detailDescription))
                    .font(.sora(12))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            if env.aiConfigs.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, horizontalInset)
        .padding(.top, 50)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if section == .overview {
            AIConfigsOverviewView(searchText: searchText)
        } else {
            AIConfigsWorkspaceView(
                section: section,
                searchText: searchText,
                selectedProjectID: $selectedProjectID,
                selectedDocumentID: $selectedDocumentID
            )
        }
    }

    private func syncSelection() {
        guard section != .overview else { return }

        let projectID = env.aiConfigs.resolvedProjectID(
            current: selectedProjectID.isEmpty ? nil : selectedProjectID,
            section: section,
            query: searchText
        )
        selectedProjectID = projectID ?? ""

        let documentID = env.aiConfigs.resolvedDocumentID(
            current: selectedDocumentID.isEmpty ? nil : selectedDocumentID,
            projectID: projectID,
            section: section,
            query: searchText
        )
        selectedDocumentID = documentID ?? ""
    }
}

#if DEBUG
#Preview("Configs detail") {
    @Previewable @State var projectID = ""
    @Previewable @State var documentID = ""

    return AIConfigsDetailView(
        section: .overview,
        searchText: "",
        selectedProjectID: $projectID,
        selectedDocumentID: $documentID
    )
    .environment(AppEnvironment.preview())
    .frame(width: 980, height: 720)
    .background(Color.stxBackground)
}
#endif
