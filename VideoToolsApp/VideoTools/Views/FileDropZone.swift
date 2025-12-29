import SwiftUI
import UniformTypeIdentifiers

struct FileDropZone: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Group {
            if appState.videoFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(appState.isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    appState.isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            appState.addFiles(urls: urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                appState.isDropTargeted = targeted
            }
        }
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            
            Text("Drop video files here")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("or click + to browse")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }
    
    private var fileList: some View {
        let _ = print("FileDropZone: DEBUG - fileList computed, videoFiles.count = \(appState.videoFiles.count), updateVersion = \(appState.updateVersion)")
        return List {
            ForEach(appState.videoFiles) { file in
                let _ = print("FileDropZone: DEBUG - ForEach rendering file: \(file.filename), has metadata: \(file.metadata != nil)")
                FileRow(fileId: file.id)
                    .id("\(file.id)-\(appState.updateVersion)")
            }
            .onDelete { indexSet in
                indexSet.forEach { appState.videoFiles.remove(at: $0) }
            }
        }
        .listStyle(.inset)
    }
}

struct FileRow: View {
    @Environment(AppState.self) private var appState
    let fileId: UUID
    @State private var isExpanded = false
    
    // Get the current file from appState to ensure we always have the latest metadata
    private var file: VideoFile? {
        let found = appState.videoFiles.first { $0.id == fileId }
        if let file = found {
            print("FileRow: DEBUG - file computed property accessed for \(file.filename), has metadata: \(file.metadata != nil)")
            if let meta = file.metadata {
                print("FileRow: DEBUG - metadata = \(meta.resolution), \(meta.durationFormatted)")
            }
        } else {
            print("FileRow: DEBUG - file computed property accessed but file not found for id: \(fileId)")
        }
        return found
    }
    
    private var progress: FileProgress? {
        guard let file = file else { return nil }
        return appState.fileProgress[file.filename]
    }
    
    var body: some View {
        let _ = print("FileRow: DEBUG - body computed for fileId: \(fileId)")
        if let file = file {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    statusIcon
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.filename)
                            .font(.body)
                            .lineLimit(1)
                        
                        if let metadata = file.metadata {
                            let _ = print("FileRow: DEBUG - Rendering metadata view for \(file.filename)")
                            Text("\(metadata.resolution) • \(metadata.durationFormatted) • \(metadata.frameRateFormatted) • \(metadata.bitRateMbps)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        } else {
                            let _ = print("FileRow: DEBUG - Rendering 'Loading metadata...' for \(file.filename)")
                            Text("Loading metadata...")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    
                    Spacer()
                    
                    if let progress = progress {
                        progressIndicator(progress)
                    }
                    
                    if file.metadata != nil {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        } label: {
                            Image(systemName: "info.circle")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button {
                        appState.removeFile(file)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
                
                if isExpanded, let metadata = file.metadata {
                    MetadataDetailView(metadata: metadata)
                        .padding(.leading, 32)
                        .padding(.vertical, 8)
                }
            }
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        if let progress = progress {
            switch progress.status {
            case .pending:
                Image(systemName: "clock")
                    .foregroundStyle(.secondary)
            case .processing:
                ProgressView()
                    .controlSize(.small)
            case .completed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .error:
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
        }
    }
    
    @ViewBuilder
    private func progressIndicator(_ progress: FileProgress) -> some View {
        if progress.segmentsTotal > 0 {
            Text("\(progress.segmentsCompleted)/\(progress.segmentsTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

struct MetadataDetailView: View {
    let metadata: VideoMetadata
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 16) {
                metadataItem("Resolution", value: metadata.resolution)
                metadataItem("Duration", value: metadata.durationFormatted)
            }
            HStack(spacing: 16) {
                metadataItem("Frame Rate", value: metadata.frameRateFormatted)
                metadataItem("Bit Rate", value: metadata.bitRateMbps)
            }
            HStack(spacing: 16) {
                metadataItem("Video Codec", value: metadata.videoCodec)
                if metadata.hasAudio {
                    metadataItem("Audio", value: "\(metadata.audioCodec ?? "Unknown") • \(metadata.audioSampleRateFormatted ?? "?") • \(metadata.audioChannels ?? 0)ch")
                } else {
                    metadataItem("Audio", value: "None")
                }
            }
        }
        .font(.caption)
        .padding(10)
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private func metadataItem(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .foregroundStyle(.tertiary)
            Text(value)
                .foregroundStyle(.primary)
        }
        .frame(minWidth: 100, alignment: .leading)
    }
}

#Preview {
    FileDropZone()
        .environment(AppState())
        .frame(width: 300, height: 400)
}
