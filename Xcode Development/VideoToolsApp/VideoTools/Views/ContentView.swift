import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(MediaPlayerManager.self) private var playerManager

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            headerView

            Divider()

            // Content area — main tools + optional media player sidebar
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Main content
                    mainContentView
                        .frame(width: appState.isMediaPlayerVisible
                            ? geo.size.width * 0.25
                            : geo.size.width)

                    // Media player sidebar (75% of content area)
                    if appState.isMediaPlayerVisible {
                        Divider()
                        MediaPlayerView()
                            .frame(width: geo.size.width * 0.75)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: appState.isMediaPlayerVisible)
            }

            Divider()

            footerView
        }
        .frame(minWidth: 750, minHeight: 550)
        .background(.background)
        .fileImporter(
            isPresented: $state.showingFilePicker,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                appState.addFiles(urls: urls)
            }
        }
        .onChange(of: playerManager.currentFile?.id) { _, newValue in
            if newValue != nil {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.isMediaPlayerVisible = true
                }
            }
        }
        .onChange(of: appState.isMediaPlayerVisible) { _, isVisible in
            if !isVisible {
                playerManager.stop()
            }
        }
        .onChange(of: appState.videoFiles) { _, newFiles in
            playerManager.updatePlaylist(newFiles)
        }
        .onChange(of: appState.selectedMode) { _, _ in
            if appState.isMediaPlayerVisible {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.isMediaPlayerVisible = false
                }
            }
        }
    }

    // MARK: - Main Content

    private var mainContentView: some View {
        Group {
            if appState.selectedMode == .mediaPlayer {
                VStack(spacing: 0) {
                    videoFileListHeader
                    Divider()
                    FileDropZone()
                }
                .background(.background.secondary)
            } else {
                HSplitView {
                    fileListView
                        .frame(minWidth: 280, idealWidth: 320)

                    settingsView
                        .frame(minWidth: 300, idealWidth: 380)
                }
            }
        }
    }
    
    private var headerView: some View {
        HStack(spacing: 8) {
            // Video Processing group
            ForEach(ToolMode.allCases.filter { $0.group == .videoProcessing }) { mode in
                ModeButton(mode: mode, isSelected: appState.selectedMode == mode) {
                    withAnimation(.smooth(duration: 0.2)) {
                        appState.selectedMode = mode
                    }
                }
            }

            Divider()
                .frame(height: 24)

            // File Management group
            ForEach(ToolMode.allCases.filter { $0.group == .fileManagement }) { mode in
                ModeButton(mode: mode, isSelected: appState.selectedMode == mode) {
                    withAnimation(.smooth(duration: 0.2)) {
                        appState.selectedMode = mode
                    }
                }
            }

            Divider()
                .frame(height: 24)

            // Inspection group
            ForEach(ToolMode.allCases.filter { $0.group == .inspection }) { mode in
                ModeButton(mode: mode, isSelected: appState.selectedMode == mode) {
                    withAnimation(.smooth(duration: 0.2)) {
                        appState.selectedMode = mode
                    }
                }
            }

            Divider()
                .frame(height: 24)

            // Playback group
            ForEach(ToolMode.allCases.filter { $0.group == .playback }) { mode in
                ModeButton(mode: mode, isSelected: appState.selectedMode == mode) {
                    withAnimation(.smooth(duration: 0.2)) {
                        appState.selectedMode = mode
                    }
                }
            }

            Spacer()

            // Media player sidebar toggle
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.isMediaPlayerVisible.toggle()
                }
            } label: {
                Image(systemName: appState.isMediaPlayerVisible
                    ? "sidebar.trailing"
                    : "play.rectangle")
                    .foregroundStyle(appState.isMediaPlayerVisible ? .primary : .secondary)
            }
            .buttonStyle(.plain)
            .help(appState.isMediaPlayerVisible ? "Hide media player" : "Show media player")

            Text("Video Tools")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    private var fileListView: some View {
        VStack(spacing: 0) {
            switch appState.selectedMode {
            case .split, .separate, .gif, .merge, .mediaPlayer:
                videoFileListHeader
                Divider()
                FileDropZone()

            case .renameVideos, .renamePhotos:
                renameListHeader
                Divider()
                if appState.renameSubMode == .findReplace {
                    FindReplacePickerView(mode: appState.selectedMode)
                } else {
                    FolderPickerView(mode: appState.selectedMode)
                }

            case .metadata:
                metadataListHeader
                Divider()
                MetadataFilePickerView()
            }
        }
        .background(.background.secondary)
    }

    private var videoFileListHeader: some View {
        HStack {
            Text("Files")
                .font(.headline)

            Spacer()

            Button {
                appState.showingFilePicker = true
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)

            Button {
                appState.clearFiles()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(appState.videoFiles.isEmpty)
        }
        .padding()
    }

    private var renameListHeader: some View {
        @Bindable var state = appState

        return VStack(spacing: 8) {
            Picker("Mode", selection: $state.renameSubMode) {
                ForEach(RenameSubMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Text(appState.renameSubMode == .folderRename ? "Folder" : "Files")
                    .font(.headline)

                Spacer()

                if appState.renameSubMode == .folderRename {
                    if appState.activeRenameFolder != nil {
                        Button {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                appState.selectFolder(url: url, forMode: appState.selectedMode)
                            }
                        } label: {
                            Image(systemName: "folder.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .help("Change folder")

                        Button {
                            appState.clearRenameFolder()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding()
    }

    private var metadataListHeader: some View {
        HStack {
            Text("File")
                .font(.headline)

            Spacer()

            if appState.metadataFile != nil {
                Button {
                    appState.clearMetadata()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
    }
    
    private var settingsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch appState.selectedMode {
                case .split:
                    SplitterSettingsView()
                case .separate:
                    SeparatorSettingsView()
                case .gif:
                    GifSettingsView()
                case .merge:
                    MergerSettingsView()
                case .renameVideos, .renamePhotos:
                    if appState.renameSubMode == .findReplace {
                        FindReplaceSettingsView()
                    } else {
                        RenameSettingsView(mode: appState.selectedMode)
                    }
                case .metadata:
                    MetadataSettingsView()
                case .mediaPlayer:
                    EmptyView()
                }
            }
            .padding()
        }
        .background(.background)
    }
    
    private var footerView: some View {
        HStack {
            statusView

            Spacer()

            if appState.selectedMode.isProcessable {
                ProcessButton()
            }
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var statusView: some View {
        switch appState.processingStatus {
        case .idle:
            switch appState.selectedMode {
            case .split, .separate, .gif, .merge, .mediaPlayer:
                Label("\(appState.videoFiles.count) file(s) selected", systemImage: "film")
                    .foregroundStyle(.secondary)
            case .renameVideos, .renamePhotos:
                if appState.renameSubMode == .findReplace {
                    let total = appState.findReplaceFiles.count
                    let matches = appState.findReplaceMatchCount
                    Label("\(matches) of \(total) file(s) to rename", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                } else {
                    let count = appState.activeRenameFolder?.discoveredFiles.count ?? 0
                    Label("\(count) file(s) to rename", systemImage: "pencil.line")
                        .foregroundStyle(.secondary)
                }
            case .metadata:
                if appState.metadataFile != nil {
                    Label("Metadata loaded", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Select a video file", systemImage: "info.circle")
                        .foregroundStyle(.tertiary)
                }
            }

        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(appState.selectedMode.isFolderBased ? "Renaming..." : "Processing...")
            }

        case .completed(let successful, let failed):
            Label("\(successful) succeeded, \(failed) failed", systemImage: "checkmark.circle")
                .foregroundStyle(failed > 0 ? .orange : .green)

        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

}

struct ModeButton: View {
    let mode: ToolMode
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                Text(mode.rawValue)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? .primary : .secondary)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .environment(MediaPlayerManager())
}
