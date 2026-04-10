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
    var splitDurationUnit: DurationUnit = .seconds
    var fpsMode: FPSMode = .single
    var fpsValue: Double = 30
    var outputCodec: OutputCodec = .copy
    var qualityMode: QualityMode = .quality
    var qualityValue: Double = 65   // VideoToolbox -q:v scale (0-100, higher=better)
    var outputFolderMode: OutputFolderMode = .perFile

    // Separator settings
    var sampleRateMode: SampleRateMode = .single
    var sampleRate: SampleRate = .hz48000
    var audioChannelMode: AudioChannelMode = .stereo

    // Rename settings
    var renameVideoFolder: RenameFolder?
    var renamePhotoFolder: RenameFolder?
    var renamePrefix: String = ""
    var renameStartNumber: Int = 1
    var renamePaddingWidth: Int = 6
    var renameSortOrder: RenameSortOrder = .byName
    var renameSortAscending: Bool = true
    var showingFolderPicker: Bool = false
    var showRenameConfirmation: Bool = false
    var renameFolderAlert: RenameFolderAlert?

    // Metadata settings
    var metadataFile: MetadataFile?
    var showingMetadataFilePicker: Bool = false

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
    var gifOutputFormat: GifOutputFormat = .gif
    var gifWebPQuality: Double = 80
    var gifTrimStart: Double = 0
    var gifTrimEnd: Double? = nil
    var gifCutSegments: [CutSegment] = []
    
    // Merge settings
    var mergeOutputFilename: String = "merged_output"
    var mergeAspectMode: MergeAspectMode = .letterbox
    var mergeOutputCodec: OutputCodec = .h264
    var mergeQualityMode: QualityMode = .quality
    var mergeQualityValue: Double = 65
    var mergeFpsValue: Double = 30
    var mergeOutputLocation: MergeOutputLocation = .firstFile
    var mergeCustomOutputDir: URL? = nil

    // Parallel processing
    var parallelJobs: Int = 4
    
    /// Split value converted to seconds for the Python script
    var splitValueInSeconds: Double {
        switch splitMethod {
        case .duration:
            return splitDurationUnit == .minutes ? splitValue * 60 : splitValue
        case .segments:
            return splitValue
        case .reencodeOnly:
            return 1 // 1 segment = full video
        }
    }

    private let prober = VideoProber()
    
    var canProcess: Bool {
        guard processingStatus != .running else { return false }
        switch selectedMode {
        case .split, .separate, .gif:
            return !videoFiles.isEmpty
        case .merge:
            return videoFiles.count >= 2
        case .renameVideos:
            return !(renameVideoFolder?.discoveredFiles.isEmpty ?? true)
        case .renamePhotos:
            return !(renamePhotoFolder?.discoveredFiles.isEmpty ?? true)
        case .metadata:
            return false
        }
    }

    /// The active rename folder for the current mode
    var activeRenameFolder: RenameFolder? {
        get {
            switch selectedMode {
            case .renameVideos: return renameVideoFolder
            case .renamePhotos: return renamePhotoFolder
            default: return nil
            }
        }
        set {
            switch selectedMode {
            case .renameVideos: renameVideoFolder = newValue
            case .renamePhotos: renamePhotoFolder = newValue
            default: break
            }
        }
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
            if metadata?.duration != nil, gifTrimEnd == nil {
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
    
    // MARK: - Merge Operations

    func moveFile(from source: IndexSet, to destination: Int) {
        videoFiles.move(fromOffsets: source, toOffset: destination)
    }

    func buildMergeConfig() -> MergerConfig {
        let outputDir: String
        if mergeOutputLocation == .custom, let customDir = mergeCustomOutputDir {
            outputDir = customDir.path
        } else {
            outputDir = videoFiles.first.map {
                URL(fileURLWithPath: $0.path).deletingLastPathComponent().path
            } ?? "."
        }

        return MergerConfig(
            files: videoFiles.map(\.path),
            config: .init(
                output_filename: mergeOutputFilename,
                aspect_mode: mergeAspectMode.configValue,
                output_codec: mergeOutputCodec.configValue,
                quality_mode: mergeQualityMode.configValue,
                quality_value: mergeQualityValue,
                fps_value: mergeFpsValue,
                output_dir: outputDir
            )
        )
    }

    // MARK: - Rename Operations

    func selectFolder(url: URL, forMode mode: ToolMode) {
        let extensions = mode.supportedExtensions
        guard !extensions.isEmpty else { return }

        var folder = RenameFolder(url: url)

        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let allFiles = contents.filter { !$0.hasDirectoryPath }
        let matchingFiles = allFiles.filter { extensions.contains($0.pathExtension.lowercased()) }

        // Alert user if no matching files found
        if matchingFiles.isEmpty {
            let wrongTypeExts: Set<String> = mode == .renameVideos
                ? ["png", "jpg", "jpeg", "tiff", "gif"]
                : ["mp4", "mov", "avi", "mkv", "m4v", "flv", "wmv"]
            let wrongTypeCount = allFiles.filter { wrongTypeExts.contains($0.pathExtension.lowercased()) }.count

            if wrongTypeCount > 0 {
                let expected = mode == .renameVideos ? "video" : "image"
                let found = mode == .renameVideos ? "image" : "video"
                renameFolderAlert = .wrongFileType(
                    message: "No \(expected) files found in this folder. Found \(wrongTypeCount) \(found) file\(wrongTypeCount == 1 ? "" : "s") instead. Try the \(mode == .renameVideos ? "Rename Photos" : "Rename Videos") mode."
                )
            } else {
                let expected = mode == .renameVideos ? "video" : "image"
                let extList = extensions.map { ".\($0)" }.joined(separator: ", ")
                renameFolderAlert = .noMatchingFiles(
                    message: "No \(expected) files found in this folder. Looking for: \(extList)"
                )
            }
            return
        }

        // Sort files
        let sorted = sortFiles(matchingFiles, by: renameSortOrder, ascending: renameSortAscending)

        // Set prefix to folder name by default
        renamePrefix = url.lastPathComponent

        // Generate entries with proposed names
        folder.discoveredFiles = sorted.enumerated().map { index, fileURL in
            let number = renameStartNumber + index
            let padded = String(format: "%0\(renamePaddingWidth)d", number)
            let ext = fileURL.pathExtension.lowercased()
            let proposed = "\(renamePrefix)_\(padded).\(ext)"
            return RenameFileEntry(
                originalURL: fileURL,
                originalName: fileURL.lastPathComponent,
                proposedName: proposed
            )
        }

        // Detect collisions
        detectCollisions(in: &folder)

        switch mode {
        case .renameVideos: renameVideoFolder = folder
        case .renamePhotos: renamePhotoFolder = folder
        default: break
        }
    }

    func updateRenamePreview() {
        guard var folder = activeRenameFolder else { return }
        let prefix = renamePrefix.isEmpty ? (folder.name) : renamePrefix

        let urls = folder.discoveredFiles.map(\.originalURL)
        let sorted = sortFiles(urls, by: renameSortOrder, ascending: renameSortAscending)

        folder.discoveredFiles = sorted.enumerated().map { index, fileURL in
            let number = renameStartNumber + index
            let padded = String(format: "%0\(renamePaddingWidth)d", number)
            let ext = fileURL.pathExtension.lowercased()
            let proposed = "\(prefix)_\(padded).\(ext)"
            return RenameFileEntry(
                originalURL: fileURL,
                originalName: fileURL.lastPathComponent,
                proposedName: proposed
            )
        }

        detectCollisions(in: &folder)
        activeRenameFolder = folder
    }

    private func sortFiles(_ files: [URL], by order: RenameSortOrder, ascending: Bool) -> [URL] {
        let sorted = files.sorted { a, b in
            switch order {
            case .byName:
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            case .byDateModified:
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return dateA < dateB
            case .byDateCreated:
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return dateA < dateB
            case .bySize:
                let sizeA = (try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                let sizeB = (try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                return sizeA < sizeB
            }
        }
        return ascending ? sorted : sorted.reversed()
    }

    private func detectCollisions(in folder: inout RenameFolder) {
        // Check if any proposed name matches an existing file that's NOT in our rename set
        let originalNames = Set(folder.discoveredFiles.map(\.originalName))
        let fm = FileManager.default

        for i in folder.discoveredFiles.indices {
            let proposed = folder.discoveredFiles[i].proposedName
            let proposedURL = folder.url.appendingPathComponent(proposed)

            // Collision if: proposed name exists on disk AND it's not one of our files being renamed
            if fm.fileExists(atPath: proposedURL.path) && !originalNames.contains(proposed) {
                folder.discoveredFiles[i].status = .collision
            } else {
                folder.discoveredFiles[i].status = .pending
            }
        }
    }

    func clearRenameFolder() {
        activeRenameFolder = nil
        renamePrefix = ""
        renameStartNumber = 1
        processingStatus = .idle
    }

    // MARK: - Metadata Operations

    func loadMetadata(url: URL) {
        metadataFile = MetadataFile(url: url)
        Task {
            let metadata = await prober.probe(url: url)
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int64
            metadataFile?.metadata = metadata
            metadataFile?.fileSize = fileSize
            metadataFile?.isLoading = false
            updateVersion += 1
        }
    }

    func clearMetadata() {
        metadataFile = nil
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
                output_format: gifOutputFormat.rawValue.lowercased(),
                webp_quality: Int(gifWebPQuality),
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
        let output_format: String
        let webp_quality: Int
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

struct MergerConfig: Encodable {
    let files: [String]
    let config: Settings

    struct Settings: Encodable {
        let output_filename: String
        let aspect_mode: String
        let output_codec: String
        let quality_mode: String
        let quality_value: Double
        let fps_value: Double
        let output_dir: String
    }
}
