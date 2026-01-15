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
    var updateVersion: Int = 0
    
    // Splitter settings
    var splitMethod: SplitMethod = .duration
    var splitValue: Double = 60
    var fpsMode: FPSMode = .single
    var fpsValue: Double = 30
    
    // Separator settings
    var sampleRateMode: SampleRateMode = .single
    var sampleRate: SampleRate = .hz48000
    
    // GIF settings
    var gifResolutionMode: GifResolutionMode = .scale
    var gifScalePercent: Double = 50
    var gifFixedWidth: Int = 480
    var gifCustomWidth: Int = 640
    var gifCustomHeight: Int = 480
    var gifFrameRate: Double = 15
    var gifSpeedMultiplier: Double = 1.0
    var gifLoopMode: GifLoopMode = .infinite
    var gifLoopCount: Int = 3
    var gifDitherMethod: GifDitherMethod = .floydSteinberg
    var gifColorCount: Double = 256
    var gifTrimStart: Double = 0
    var gifTrimEnd: Double? = nil
    var gifCutSegments: [CutSegment] = []
    
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
        
        Task {
            await probeNewFiles(newFiles)
        }
    }
    
    private func probeNewFiles(_ files: [VideoFile]) async {
        for file in files {
            guard let index = videoFiles.firstIndex(where: { $0.id == file.id }) else {
                continue
            }
            
            let metadata = await prober.probe(url: file.url)
            
            var updatedFiles = videoFiles
            var updatedFile = updatedFiles[index]
            updatedFile.metadata = metadata
            updatedFiles[index] = updatedFile
            
            withAnimation {
                videoFiles = updatedFiles
                updateVersion += 1
            }
            
            // Update trim end to video duration for GIF mode
            if let duration = metadata?.duration, gifTrimEnd == nil {
                gifTrimEnd = nil // Keep as nil to use duration as placeholder
            }
        }
    }
    
    func removeFile(_ file: VideoFile) {
        withAnimation {
            videoFiles.removeAll { $0.id == file.id }
        }
    }
    
    func clearFiles() {
        fileProgress.removeAll()
        processingStatus = .idle
        withAnimation {
            videoFiles = []
        }
        // Reset GIF trim settings
        gifTrimStart = 0
        gifTrimEnd = nil
        gifCutSegments = []
    }
    
    func updateFileProgress(fileId: String, update: (inout FileProgress) -> Void) {
        if var progress = fileProgress[fileId] {
            update(&progress)
            fileProgress[fileId] = progress
        }
    }
    
    // MARK: - GIF Config Builder
    
    func buildGifConfig() -> GifConfig {
        let loopValue: Int = switch gifLoopMode {
        case .infinite: 0
        case .once: 1
        case .custom: gifLoopCount
        }
        
        let resolutionConfig: GifConfig.ResolutionConfig = switch gifResolutionMode {
        case .original:
            .init(mode: "original", scalePercent: nil, width: nil, height: nil)
        case .scale:
            .init(mode: "scale", scalePercent: Int(gifScalePercent), width: nil, height: nil)
        case .width:
            .init(mode: "width", scalePercent: nil, width: gifFixedWidth, height: nil)
        case .custom:
            .init(mode: "custom", scalePercent: nil, width: gifCustomWidth, height: gifCustomHeight)
        }
        
        return GifConfig(
            files: videoFiles.map(\.path),
            config: .init(
                resolution: resolutionConfig,
                frame_rate: gifFrameRate,
                speed_multiplier: gifSpeedMultiplier,
                loop_count: loopValue,
                dither_method: gifDitherMethod.ffmpegValue,
                color_count: Int(gifColorCount),
                trim_start: gifTrimStart,
                trim_end: gifTrimEnd,
                cut_segments: gifCutSegments.map { ["start": $0.startTime, "end": $0.endTime] }
            )
        )
    }
}

struct GifConfig: Encodable {
    let files: [String]
    let config: Settings
    
    struct Settings: Encodable {
        let resolution: ResolutionConfig
        let frame_rate: Double
        let speed_multiplier: Double
        let loop_count: Int
        let dither_method: String
        let color_count: Int
        let trim_start: Double
        let trim_end: Double?
        let cut_segments: [[String: Double]]
    }
    
    struct ResolutionConfig: Encodable {
        let mode: String
        let scalePercent: Int?
        let width: Int?
        let height: Int?
    }
}
