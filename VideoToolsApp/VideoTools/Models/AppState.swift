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
    var updateVersion: Int = 0  // Force view updates when metadata changes
    
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
    
    private let prober = VideoProber()
    
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
        
        // Probe metadata for new files
        Task {
            await probeNewFiles(newFiles)
        }
    }
    
    private func probeNewFiles(_ files: [VideoFile]) async {
        for file in files {
            guard let index = videoFiles.firstIndex(where: { $0.id == file.id }) else {
                print("AppState: DEBUG - File \(file.filename) not found in videoFiles array")
                continue
            }
            print("AppState: Probing metadata for \(file.filename)")
            print("AppState: DEBUG - Before probe: videoFiles.count = \(videoFiles.count), file at index \(index) has metadata: \(videoFiles[index].metadata != nil)")
            
            let metadata = await prober.probe(url: file.url)
            if let metadata = metadata {
                print("AppState: Successfully extracted metadata for \(file.filename): \(metadata.resolution), \(metadata.durationFormatted), \(metadata.frameRateFormatted)")
            } else {
                print("AppState: Failed to extract metadata for \(file.filename)")
            }
            
            // Reassign entire array to trigger SwiftUI observation
            // Since AppState is @MainActor, we're already on the main thread
            var updatedFiles = videoFiles
            var updatedFile = updatedFiles[index]
            let hadMetadata = updatedFile.metadata != nil
            updatedFile.metadata = metadata
            updatedFiles[index] = updatedFile
            print("AppState: DEBUG - Before assignment: videoFiles.count = \(videoFiles.count), updatedFiles.count = \(updatedFiles.count)")
            print("AppState: DEBUG - Updated file metadata changed: \(hadMetadata) -> \(updatedFile.metadata != nil)")
            
            // Use withAnimation to ensure SwiftUI detects the change
            withAnimation {
                videoFiles = updatedFiles
                updateVersion += 1  // Increment to force view refresh
            }
            print("AppState: DEBUG - After assignment: videoFiles.count = \(videoFiles.count), file at index \(index) has metadata: \(videoFiles[index].metadata != nil), updateVersion = \(updateVersion)")
            
            // Verify the update
            if let verifyFile = videoFiles.first(where: { $0.id == file.id }) {
                print("AppState: DEBUG - Verification: file \(verifyFile.filename) has metadata: \(verifyFile.metadata != nil)")
                if let meta = verifyFile.metadata {
                    print("AppState: DEBUG - Verification: metadata = \(meta.resolution), \(meta.durationFormatted)")
                }
            } else {
                print("AppState: DEBUG - ERROR: File not found after update!")
            }
        }
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
