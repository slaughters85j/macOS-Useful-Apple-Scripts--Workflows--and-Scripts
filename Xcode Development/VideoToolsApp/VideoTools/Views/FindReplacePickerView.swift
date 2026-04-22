//
//  FindReplacePickerView.swift
//  VideoTools
//
//  Created by John Slaughter on 04/21/26.
//
//  Description:
//  Left panel view for Find & Replace rename mode. Accepts individual file drops
//  from any directory, displays file list with rename preview, and supports
//  multi-select file picker.

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Find & Replace Picker View

/// Left panel for Find & Replace mode — file drop zone + file list with rename preview.
struct FindReplacePickerView: View {
    let mode: ToolMode
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if !appState.findReplaceFiles.isEmpty {
                filesHeader
                Divider()
                fileList
            } else {
                emptyState
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Files Header

    private var filesHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.secondary)

                let fileCount = appState.findReplaceFiles.count
                let dirCount = appState.findReplaceDirectoryCount
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") from \(dirCount) director\(dirCount == 1 ? "y" : "ies")")
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)

                Spacer()

                Button {
                    appState.clearFindReplaceFiles()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear all files")
            }

            HStack(spacing: 12) {
                let matchCount = appState.findReplaceMatchCount
                Label("\(matchCount) will rename", systemImage: "pencil.line")
                    .font(.caption)
                    .foregroundStyle(matchCount > 0 ? .secondary : .tertiary)

                let collisions = appState.findReplaceFiles.filter { $0.status == .collision }.count
                if collisions > 0 {
                    Label("\(collisions) collision\(collisions == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(appState.findReplaceFiles) { entry in
                    FindReplaceFileRow(entry: entry) {
                        appState.removeFindReplaceFile(entry)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "doc.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("Drop files here")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(mode == .renameVideos
                 ? "Videos (.mp4, .mov, .avi, .mkv, .m4v, .flv, .wmv)"
                 : "Images (.png, .jpg, .jpeg, .tiff, .gif)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Choose Files...") {
                pickFiles()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select \(mode == .renameVideos ? "video" : "image") files to rename"

        let extensions = mode.supportedExtensions
        if !extensions.isEmpty {
            panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        }

        if panel.runModal() == .OK {
            appState.addFindReplaceFiles(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                defer { group.leave() }
                guard let data = data as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                urls.append(url)
            }
        }

        group.notify(queue: .main) {
            appState.addFindReplaceFiles(urls: urls)
        }
        return true
    }
}

// MARK: - Find & Replace File Row

struct FindReplaceFileRow: View {
    let entry: RenameFileEntry
    let onRemove: () -> Void

    private var hasChange: Bool { entry.proposedName != entry.originalName }

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                // Directory path
                Text(entry.originalURL.deletingLastPathComponent().path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                // Original name
                Text(entry.originalName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(hasChange ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Proposed name (only if different)
                if hasChange {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)

                        Text(entry.proposedName)
                            .font(.system(.caption, design: .monospaced, weight: .medium))
                            .foregroundStyle(entry.status == .collision ? .orange : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .help("Remove file")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if entry.status == .collision {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if hasChange {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
        } else {
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(entry.status == .collision ? Color.orange.opacity(0.05) : Color.clear)
    }
}

// MARK: - Preview

#Preview {
    FindReplacePickerView(mode: .renameVideos)
        .environment(AppState())
        .frame(width: 320, height: 400)
}
