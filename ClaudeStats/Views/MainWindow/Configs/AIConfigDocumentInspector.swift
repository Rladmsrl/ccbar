import AppKit
import SwiftUI

struct AIConfigDocumentInspector: View {
    let document: AIConfigDocument?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let document {
                previewToolbar(document)
                StxRule()
                if !document.diagnostics.isEmpty {
                    diagnostics(document.diagnostics)
                    StxRule()
                }
                previewBody(document)
                StxRule()
                previewStatus(document)
            } else {
                AIConfigsEmptyState(
                    title: "Select a file",
                    message: "Choose a config file to inspect its read-only preview and diagnostics."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .appSurface(.plainFill)
    }

    private func previewToolbar(_ document: AIConfigDocument) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: document.kind.symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.stxMuted)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(document.title)
                        .font(.sora(13, weight: .semibold))
                        .lineLimit(1)
                    AIConfigsBadge(text: document.fileKind.displayName, color: Color.stxMuted)
                    AIConfigsBadge(text: document.provider.shortName, color: document.provider.accentColor)
                    if !document.exists {
                        AIConfigsBadge(text: "Missing", color: Color.stxMuted)
                    }
                }
                Text(document.displayPath)
                    .font(.sora(10))
                    .foregroundStyle(Color.stxMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                actionButtons(document, showLabels: true)
                actionButtons(document, showLabels: false)
            }
        }
        .padding(14)
    }

    private func actionButtons(_ document: AIConfigDocument, showLabels: Bool) -> some View {
        HStack(spacing: 8) {
            toolbarButton("Open", systemImage: "arrow.up.right.square", showLabels: showLabels, disabled: !document.exists) {
                NSWorkspace.shared.open(URL(fileURLWithPath: document.path))
            }
            toolbarButton("Reveal", systemImage: "finder", showLabels: showLabels, disabled: !document.exists) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: document.path)])
            }
            toolbarButton("Refresh", systemImage: "arrow.clockwise", showLabels: showLabels, disabled: false, action: refresh)
        }
    }

    private func toolbarButton(
        _ title: String,
        systemImage: String,
        showLabels: Bool,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if showLabels {
                Label(LocalizedStringKey(title), systemImage: systemImage)
            } else {
                Image(systemName: systemImage)
            }
        }
        .controlSize(.small)
        .help(LocalizedStringKey(title))
        .disabled(disabled)
    }

    private func diagnostics(_ diagnostics: [AIConfigDiagnostic]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(diagnostics) { diagnostic in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: diagnostic.severity == .error ? "exclamationmark.triangle.fill" : "exclamationmark.triangle")
                        .foregroundStyle(diagnostic.severity == .error ? Color(red: 0.85, green: 0.22, blue: 0.18) : Color(red: 0.92, green: 0.58, blue: 0.16))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(diagnostic.message)
                            .font(.sora(10, weight: .medium))
                            .lineLimit(2)
                        if let location = diagnostic.locationDisplay {
                            Text(location)
                                .font(.sora(9))
                                .foregroundStyle(Color.stxMuted)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func previewBody(_ document: AIConfigDocument) -> some View {
        if !document.exists {
            Text("This expected file is not present.")
                .font(.sora(12))
                .foregroundStyle(Color.stxMuted)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if document.isPreviewTruncated {
            Text("Preview skipped because this file is larger than \(Format.bytes(AIConfigScanner.previewByteLimit)).")
                .font(.sora(12))
                .foregroundStyle(Color.stxMuted)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let content = document.contentPreview {
            ConfigurationTextEditor(
                text: .constant(content),
                fileKind: document.fileKind,
                isEditable: false,
                onCursorChange: { _, _ in }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))
        } else {
            Text("No preview available.")
                .font(.sora(12))
                .foregroundStyle(Color.stxMuted)
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func previewStatus(_ document: AIConfigDocument) -> some View {
        HStack(spacing: 12) {
            if let fileSize = document.fileSize {
                Text(Format.bytes(Int(fileSize)))
            }
            if let modifiedAt = document.modifiedAt {
                Text(Format.shortDate(modifiedAt))
            }
            if document.fileKind == .markdown {
                Text("\(document.stats.headingCount) headings")
                Text("\(document.stats.uncheckedTaskCount) open tasks")
            }
            Spacer(minLength: 12)
            if document.diagnostics.isEmpty {
                Text(document.exists ? "Syntax OK" : "Missing")
                    .foregroundStyle(document.exists ? Color.stxAccent : Color.stxMuted)
            } else {
                Text("\(document.diagnostics.count) diagnostics")
            }
        }
        .font(.sora(10))
        .foregroundStyle(Color.stxMuted)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
