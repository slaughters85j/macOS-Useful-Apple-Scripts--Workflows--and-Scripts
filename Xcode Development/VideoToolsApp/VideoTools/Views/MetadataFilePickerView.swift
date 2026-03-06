import SwiftUI
import UniformTypeIdentifiers

/// Left panel view for metadata mode — single file selection with drag-and-drop.
struct MetadataFilePickerView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            if let file = appState.metadataFile {
                fileInfoPanel(file)
            } else {
                emptyState
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Subviews

    private func fileInfoPanel(_ file: MetadataFile) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "film.fill")
                        .foregroundStyle(.blue)
                    Text(file.filename)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer()

                    Button {
                        appState.clearMetadata()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear file")
                }

                Text(file.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.head)

                if let size = file.fileSize {
                    Label(formatFileSize(size), systemImage: "doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if file.isLoading {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading metadata...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            Divider()

            // Change file button
            VStack(spacing: 12) {
                Spacer()

                Button("Choose Different File...") {
                    pickFile()
                }
                .buttonStyle(.bordered)

                Text("Or drop a video file here")
                    .font(.caption)
                    .foregroundStyle(.quaternary)

                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "info.circle")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)

            Text("Select a video file")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text("View detailed codec, format, and stream information")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button("Choose File...") {
                pickFile()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Or drop a video file here")
                .font(.caption)
                .foregroundStyle(.quaternary)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi]
        panel.message = "Select a video file to inspect"

        if panel.runModal() == .OK, let url = panel.url {
            appState.loadMetadata(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { return }

            Task { @MainActor in
                appState.loadMetadata(url: url)
            }
        }
        return true
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    MetadataFilePickerView()
        .environment(AppState())
        .frame(width: 320, height: 400)
}
