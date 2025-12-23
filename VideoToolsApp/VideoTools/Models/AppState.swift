import Foundation
import SwiftUI

@Observable
@MainActor
final class AppState {
    var selectedMode: ToolMode = .split
    var videoFiles: [VideoFile] = []
    var isDropTargeted = false
    var processingStatus: ProcessingStatus = .idle
    var fileProgress: [String: FileProgress] = [:]
    var showingFilePicker = false
    
    // Splitter settings
    var splitMethod: SplitMethod = .duration
    var splitValue: Double = 60
    var fpsMode: FPSMode = .single
    var fpsValue: Double = 30
    
    // Separator settings
    var sampleRateMode: SampleRateMode = .single
    var sampleRate: SampleRate = .hz48000
    
    // Parallel processing
    var parallelJobs: Int = 4
    
    var canProcess: Bool {
        !videoFiles.isEmpty && processingStatus != .running
    }
    
    func addFiles(urls: [URL]) {
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]
        let newFiles = urls
            .filter { videoExtensions.contains($0.pathExtension.lowercased()) }
            .filter { url in !videoFiles.contains { $0.url == url } }
            .map { VideoFile(url: $0) }
        videoFiles.append(contentsOf: newFiles)
    }
    
    func removeFile(_ file: VideoFile) {
        withAnimation {
            videoFiles.removeAll { $0.id == file.id }
        }
    }
    
    func clearFiles() {
        // Clear progress first (not displayed in List)
        fileProgress.removeAll()
        processingStatus = .idle
        // Then clear files with animation to prevent layout crash
        withAnimation {
            videoFiles = []
        }
    }
    
    func updateFileProgress(fileId: String, update: (inout FileProgress) -> Void) {
        if var progress = fileProgress[fileId] {
            update(&progress)
            fileProgress[fileId] = progress
        }
    }
}
