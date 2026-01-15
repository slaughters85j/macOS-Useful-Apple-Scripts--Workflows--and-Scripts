import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        VStack(spacing: 0) {
            headerView
            
            Divider()
            
            HSplitView {
                fileListView
                    .frame(minWidth: 280, idealWidth: 320)
                
                settingsView
                    .frame(minWidth: 300, idealWidth: 380)
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
    }
    
    private var headerView: some View {
        HStack(spacing: 12) {
            ForEach(ToolMode.allCases) { mode in
                ModeButton(mode: mode, isSelected: appState.selectedMode == mode) {
                    withAnimation(.smooth(duration: 0.2)) {
                        appState.selectedMode = mode
                    }
                }
            }
            
            Spacer()
            
            Text("Video Tools")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    private var fileListView: some View {
        VStack(spacing: 0) {
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
            
            Divider()
            
            FileDropZone()
        }
        .background(.background.secondary)
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
            
            ProcessButton()
        }
        .padding()
        .background(.ultraThinMaterial)
    }
    
    @ViewBuilder
    private var statusView: some View {
        switch appState.processingStatus {
        case .idle:
            Label("\(appState.videoFiles.count) file(s) selected", systemImage: "film")
                .foregroundStyle(.secondary)
            
        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Processing...")
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
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
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
}
