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
    var isMediaPlayerVisible = false
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

    // Rename settings (shared)
    var renameSubMode: RenameSubMode = .folderRename
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

    // Find & Replace settings
    var findReplaceFiles: [RenameFileEntry] = []
    var findText: String = ""
    var replaceText: String = ""
    var findReplaceCaseSensitive: Bool = true

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
    var gifOutputFormat: GifOutputFormat = .gif
    var gifTextFontName: String = CuratedFont.helvetica.rawValue
    var gifTrimStart: Double = 0
    var gifTrimEnd: Double? = nil
    var gifCutSegments: [CutSegment] = []
    var gifTextOverlay: TextOverlay? = nil
    var gifShowTextEditor: Bool = false

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
        case .renameVideos, .renamePhotos:
            if renameSubMode == .findReplace {
                return !findReplaceFiles.isEmpty && !findText.isEmpty
                    && findReplaceFiles.contains { $0.proposedName != $0.originalName }
            }
            return !(activeRenameFolder?.discoveredFiles.isEmpty ?? true)
        case .metadata, .mediaPlayer:
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
        // Reset GIF settings
        gifTrimStart = 0
        gifTrimEnd = nil
        gifCutSegments = []
        gifTextOverlay = nil
        gifShowTextEditor = false
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

    // MARK: - Find & Replace Operations

    /// Add individual files for find/replace renaming. Validates file type and deduplicates.
    func addFindReplaceFiles(urls: [URL]) {
        let extensions = selectedMode.supportedExtensions
        let fm = FileManager.default
        let existingPaths = Set(findReplaceFiles.map(\.originalURL.path))
        let isFirstBatch = findReplaceFiles.isEmpty

        for url in urls {
            // Skip directories
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
                continue
            }

            // Skip unsupported extensions (only filter if mode has defined extensions)
            if !extensions.isEmpty {
                guard extensions.contains(url.pathExtension.lowercased()) else { continue }
            }

            // Skip duplicates
            guard !existingPaths.contains(url.path) else { continue }

            let entry = RenameFileEntry(
                originalURL: url,
                originalName: url.lastPathComponent,
                proposedName: url.lastPathComponent
            )
            findReplaceFiles.append(entry)
        }

        // Auto-detect common prefix on first batch of files
        if isFirstBatch && findReplaceFiles.count >= 2 {
            autoDetectCommonPrefix()
        }

        updateFindReplacePreview()
    }

    /// Update proposed names by applying find/replace to each file's original name.
    func updateFindReplacePreview() {
        let options: String.CompareOptions = findReplaceCaseSensitive ? [] : .caseInsensitive

        for i in findReplaceFiles.indices {
            let original = findReplaceFiles[i].originalName
            let ext = findReplaceFiles[i].fileExtension
            let baseName = (original as NSString).deletingPathExtension

            if findText.isEmpty {
                findReplaceFiles[i].proposedName = original
            } else {
                let newBase = baseName.replacingOccurrences(of: findText, with: replaceText, options: options)
                findReplaceFiles[i].proposedName = "\(newBase).\(ext)"
            }

            // Reset status before collision detection
            findReplaceFiles[i].status = .pending
        }

        detectFindReplaceCollisions()
    }

    /// Detect naming collisions for find/replace files, grouped by parent directory.
    private func detectFindReplaceCollisions() {
        let fm = FileManager.default

        // Group file indices by parent directory
        var dirGroups: [String: [Int]] = [:]
        for i in findReplaceFiles.indices {
            let dir = findReplaceFiles[i].originalURL.deletingLastPathComponent().path
            dirGroups[dir, default: []].append(i)
        }

        for (dir, indices) in dirGroups {
            let originalNames = Set(indices.map { findReplaceFiles[$0].originalName })

            // Check for duplicate proposed names within this directory group
            var seenProposed: [String: Int] = [:]
            for i in indices {
                let proposed = findReplaceFiles[i].proposedName
                if let firstIndex = seenProposed[proposed] {
                    findReplaceFiles[i].status = .collision
                    findReplaceFiles[firstIndex].status = .collision
                } else {
                    seenProposed[proposed] = i
                }
            }

            // Check for conflicts with existing files on disk not in our rename set
            for i in indices where findReplaceFiles[i].status != .collision {
                let proposed = findReplaceFiles[i].proposedName
                guard proposed != findReplaceFiles[i].originalName else { continue }
                let targetURL = URL(fileURLWithPath: dir).appendingPathComponent(proposed)
                if fm.fileExists(atPath: targetURL.path) && !originalNames.contains(proposed) {
                    findReplaceFiles[i].status = .collision
                }
            }
        }
    }

    /// Find the longest common prefix across all file base names and set as findText.
    func autoDetectCommonPrefix() {
        guard findReplaceFiles.count >= 2 else { return }

        let baseNames = findReplaceFiles.map {
            ($0.originalName as NSString).deletingPathExtension
        }

        guard let first = baseNames.first else { return }

        var prefix = first
        for name in baseNames.dropFirst() {
            while !name.hasPrefix(prefix) && !prefix.isEmpty {
                prefix = String(prefix.dropLast())
            }
            if prefix.isEmpty { return }
        }

        // Must be at least 3 characters to be useful
        guard prefix.count >= 3 else { return }

        // Don't set if the prefix IS the entire name for all files (would blank everything)
        if baseNames.allSatisfy({ $0 == prefix }) { return }

        findText = prefix
        updateFindReplacePreview()
    }

    /// Remove a single file from the find/replace list.
    func removeFindReplaceFile(_ entry: RenameFileEntry) {
        findReplaceFiles.removeAll { $0.id == entry.id }
        updateFindReplacePreview()
    }

    /// Clear all find/replace state.
    func clearFindReplaceFiles() {
        findReplaceFiles = []
        findText = ""
        replaceText = ""
        processingStatus = .idle
    }

    /// Number of distinct parent directories in the find/replace file set.
    var findReplaceDirectoryCount: Int {
        Set(findReplaceFiles.map { $0.originalURL.deletingLastPathComponent().path }).count
    }

    /// Number of files that will actually be renamed (proposed name differs from original).
    var findReplaceMatchCount: Int {
        findReplaceFiles.filter { $0.proposedName != $0.originalName }.count
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

}
