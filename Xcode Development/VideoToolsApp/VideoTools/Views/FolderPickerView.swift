import SwiftUI
import UniformTypeIdentifiers

/// Left panel view for rename modes — folder selection + file list with rename preview.
struct FolderPickerView: View {
    let mode: ToolMode
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            if let folder = appState.activeRenameFolder {
                folderHeader(folder)
                Divider()
                fileList(folder)
            } else {
                emptyState
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .alert(
            appState.renameFolderAlert?.title ?? "",
            isPresented: Binding(
                get: { appState.renameFolderAlert != nil },
                set: { if !$0 { appState.renameFolderAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                appState.renameFolderAlert = nil
            }
        } message: {
            Text(appState.renameFolderAlert?.message ?? "")
        }
    }

    // MARK: - Subviews

    private func folderHeader(_ folder: RenameFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(folder.name)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button {
                    appState.clearRenameFolder()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Clear folder")
            }

            Text(folder.url.path)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)

            HStack(spacing: 12) {
                Label("\(folder.discoveredFiles.count) files", systemImage: mode == .renameVideos ? "film" : "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                let collisions = folder.discoveredFiles.filter { $0.status == .collision }.count
                if collisions > 0 {
                    Label("\(collisions) collision\(collisions == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding()
    }

    private func fileList(_ folder: RenameFolder) -> some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(folder.discoveredFiles) { entry in
                    RenameFileRow(entry: entry)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("Select or drop a folder")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(mode == .renameVideos
                 ? "Videos (.mp4, .mov, .avi, .mkv, .m4v, .flv, .wmv)"
                 : "Images (.png, .jpg, .jpeg, .tiff, .gif)")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Choose Folder...") {
                pickFolder()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the folder containing \(mode == .renameVideos ? "videos" : "images") to rename"

        if panel.runModal() == .OK, let url = panel.url {
            appState.selectFolder(url: url, forMode: mode)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
                  isDir.boolValue else { return }

            Task { @MainActor in
                appState.selectFolder(url: url, forMode: mode)
            }
        }
        return true
    }
}

// MARK: - File Row

struct RenameFileRow: View {
    let entry: RenameFileEntry

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.originalName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

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

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(rowBackground)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
        case .renamed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.green)
        case .collision:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.red)
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(entry.status == .collision ? Color.orange.opacity(0.05) : Color.clear)
    }
}

#Preview {
    FolderPickerView(mode: .renameVideos)
        .environment(AppState())
        .frame(width: 320, height: 400)
}
