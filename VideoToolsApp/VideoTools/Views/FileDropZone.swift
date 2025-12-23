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
        List {
            ForEach(appState.videoFiles) { file in
                FileRow(file: file)
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
    let file: VideoFile
    
    private var progress: FileProgress? {
        appState.fileProgress[file.filename]
    }
    
    var body: some View {
        HStack(spacing: 12) {
            statusIcon
            
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .font(.body)
                    .lineLimit(1)
                
                Text(file.url.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if let progress = progress {
                progressIndicator(progress)
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

#Preview {
    FileDropZone()
        .environment(AppState())
        .frame(width: 300, height: 400)
}
