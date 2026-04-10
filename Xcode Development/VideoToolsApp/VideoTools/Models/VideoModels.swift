import Foundation
import SwiftUI

// MARK: - Tool Mode Groups

enum ToolModeGroup: String, CaseIterable {
    case videoProcessing = "Video Processing"
    case fileManagement = "File Management"
    case inspection = "Inspection"
}

enum ToolMode: String, CaseIterable, Identifiable {
    case split = "Split"
    case separate = "Separate A/V"
    case gif = "GIF"
    case merge = "Merge"
    case renameVideos = "Rename Videos"
    case renamePhotos = "Rename Photos"
    case metadata = "Metadata"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .split: return "scissors"
        case .separate: return "arrow.triangle.branch"
        case .gif: return "photo.on.rectangle"
        case .merge: return "arrow.triangle.merge"
        case .renameVideos: return "film.stack"
        case .renamePhotos: return "photo.stack"
        case .metadata: return "info.circle"
        }
    }

    var description: String {
        switch self {
        case .split: return "Split videos into segments by duration or count"
        case .separate: return "Extract video and audio streams into separate files"
        case .gif: return "Convert video clips to animated GIFs"
        case .merge: return "Merge multiple videos into a single output file"
        case .renameVideos: return "Batch rename video files using folder name prefix"
        case .renamePhotos: return "Batch rename image files using folder name prefix"
        case .metadata: return "Inspect detailed video metadata"
        }
    }

    var group: ToolModeGroup {
        switch self {
        case .split, .separate, .gif, .merge: return .videoProcessing
        case .renameVideos, .renamePhotos: return .fileManagement
        case .metadata: return .inspection
        }
    }

    var isFolderBased: Bool {
        switch self {
        case .renameVideos, .renamePhotos: return true
        default: return false
        }
    }

    var isProcessable: Bool {
        switch self {
        case .metadata: return false
        default: return true
        }
    }

    /// File extensions this mode operates on (for folder-based modes)
    var supportedExtensions: Set<String> {
        switch self {
        case .renameVideos: return ["mp4", "mov", "avi", "mkv", "m4v", "flv", "wmv"]
        case .renamePhotos: return ["png", "jpg", "jpeg", "tiff", "gif"]
        default: return []
        }
    }
}

enum SplitMethod: String, CaseIterable, Identifiable {
    case duration = "By Duration"
    case segments = "By Segment Count"
    case reencodeOnly = "Re-encode Only"

    var id: String { rawValue }
}

enum DurationUnit: String, CaseIterable, Identifiable {
    case seconds = "Seconds"
    case minutes = "Minutes"

    var id: String { rawValue }
}

enum FPSMode: String, CaseIterable, Identifiable {
    case single = "Same for All"
    case perFile = "Per File"

    var id: String { rawValue }
}

enum OutputCodec: String, CaseIterable, Identifiable {
    case copy = "Keep Original"
    case h264 = "H.264"
    case hevc = "HEVC (H.265)"

    var id: String { rawValue }

    /// Value sent to Python script config JSON
    var configValue: String {
        switch self {
        case .copy: return "copy"
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }
}

enum QualityMode: String, CaseIterable, Identifiable {
    case quality = "Quality (VBR)"
    case matchBitrate = "Match Source Bitrate"

    var id: String { rawValue }

    var configValue: String {
        switch self {
        case .quality: return "quality"
        case .matchBitrate: return "match_bitrate"
        }
    }
}

enum OutputFolderMode: String, CaseIterable, Identifiable {
    case perFile = "Per-File Subfolder"
    case alongside = "Alongside Source"

    var id: String { rawValue }

    var configValue: String {
        switch self {
        case .perFile: return "per_file"
        case .alongside: return "alongside"
        }
    }
}

// MARK: - Merge Settings

enum MergeAspectMode: String, CaseIterable, Identifiable {
    case letterbox = "Letterbox"
    case cropFill = "Crop / Fill"

    var id: String { rawValue }

    var configValue: String {
        switch self {
        case .letterbox: return "letterbox"
        case .cropFill: return "crop_fill"
        }
    }
}

enum MergeOutputLocation: String, CaseIterable, Identifiable {
    case firstFile = "Same as First File"
    case custom = "Choose Folder..."

    var id: String { rawValue }
}

// MARK: - Separator Settings

enum SampleRateMode: String, CaseIterable, Identifiable {
    case single = "Same for All"
    case perFile = "Per File"

    var id: String { rawValue }
}

enum AudioChannelMode: Int, CaseIterable, Identifiable {
    case stereo = 2
    case mono = 1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .stereo: return "Stereo (2ch)"
        case .mono: return "Mono (1ch)"
        }
    }
}

enum SampleRate: Int, CaseIterable, Identifiable {
    case hz48000 = 48000
    case hz44100 = 44100
    case hz32000 = 32000
    case hz24000 = 24000
    case hz22050 = 22050
    case hz16000 = 16000
    case hz11025 = 11025
    case hz8000 = 8000
    
    var id: Int { rawValue }
    
    var displayName: String {
        switch self {
        case .hz48000: return "48,000 Hz (Professional/DVD)"
        case .hz44100: return "44,100 Hz (CD Quality)"
        case .hz32000: return "32,000 Hz (Digital Audio)"
        case .hz24000: return "24,000 Hz"
        case .hz22050: return "22,050 Hz"
        case .hz16000: return "16,000 Hz (Voice)"
        case .hz11025: return "11,025 Hz"
        case .hz8000: return "8,000 Hz (Telephony)"
        }
    }
}

// MARK: - GIF Settings

enum GifResolutionMode: String, CaseIterable, Identifiable {
    case original = "Original"
    case scale = "Scale %"
    case width = "Fixed Width"
    case custom = "Custom"
    
    var id: String { rawValue }
}

enum GifDitherMethod: String, CaseIterable, Identifiable {
    case none = "None"
    case bayer = "Bayer"
    case floydSteinberg = "Floyd-Steinberg"
    case sierra = "Sierra"
    
    var id: String { rawValue }
    
    var ffmpegValue: String {
        switch self {
        case .none: return "none"
        case .bayer: return "bayer"
        case .floydSteinberg: return "floyd_steinberg"
        case .sierra: return "sierra2_4a"
        }
    }
}

enum GifLoopMode: String, CaseIterable, Identifiable {
    case infinite = "Infinite"
    case once = "Play Once"
    case custom = "Custom Count"

    var id: String { rawValue }
}

enum GifOutputFormat: String, CaseIterable, Identifiable {
    case gif = "GIF"
    case apng = "APNG"
    case webp = "WebP"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .gif:  return "gif"
        case .apng: return "png"
        case .webp: return "webp"
        }
    }

    /// GIF only — requires two-pass palette generation
    var supportsColorPalette: Bool { self == .gif }

    /// WebP only — exposes lossy quality slider
    var supportsQualitySlider: Bool { self == .webp }
}

/// Represents a segment to REMOVE from the video
struct CutSegment: Identifiable, Codable, Hashable {
    let id: UUID
    var startTime: Double
    var endTime: Double
    
    init(id: UUID = UUID(), startTime: Double, endTime: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }
    
    var duration: Double { endTime - startTime }
    
    var displayRange: String {
        "\(formatTime(startTime)) - \(formatTime(endTime))"
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

struct GifSettings: Codable {
    var resolutionMode: String = "original"
    var scalePercent: Int = 50
    var fixedWidth: Int = 480
    var customWidth: Int = 640
    var customHeight: Int = 480
    
    var frameRate: Double = 15
    var speedMultiplier: Double = 1.0
    
    var loopMode: String = "infinite"
    var loopCount: Int = 3
    
    var ditherMethod: String = "floyd_steinberg"
    var colorCount: Int = 256
    
    var trimStart: Double = 0
    var trimEnd: Double? = nil
    var cutSegments: [CutSegment] = []
}

// MARK: - Video File

struct VideoFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var customFPS: Double?
    var customSampleRate: SampleRate?
    var metadata: VideoMetadata?
    var gifSettings: GifSettings = GifSettings()
    
    var filename: String { url.lastPathComponent }
    var path: String { url.path }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: VideoFile, rhs: VideoFile) -> Bool {
        lhs.id == rhs.id
    }
}

enum ProcessingStatus: Equatable {
    case idle
    case running
    case completed(successful: Int, failed: Int)
    case error(String)
}

struct FileProgress: Identifiable {
    let id: String
    var status: FileStatus
    var segmentsCompleted: Int
    var segmentsTotal: Int
    var outputDir: String?

    enum FileStatus {
        case pending
        case processing
        case completed
        case error(String)
    }
}

// MARK: - Rename Models

enum RenameFolderAlert: Identifiable {
    case noMatchingFiles(message: String)
    case wrongFileType(message: String)

    var id: String {
        switch self {
        case .noMatchingFiles: return "noMatch"
        case .wrongFileType: return "wrongType"
        }
    }

    var title: String {
        switch self {
        case .noMatchingFiles: return "No Matching Files"
        case .wrongFileType: return "Wrong File Type"
        }
    }

    var message: String {
        switch self {
        case .noMatchingFiles(let msg), .wrongFileType(let msg):
            return msg
        }
    }
}

enum RenameSortOrder: String, CaseIterable, Identifiable {
    case byName = "Name"
    case byDateModified = "Date Modified"
    case byDateCreated = "Date Created"
    case bySize = "Size"

    var id: String { rawValue }
}

struct RenameFileEntry: Identifiable {
    let id = UUID()
    let originalURL: URL
    let originalName: String
    var proposedName: String
    var status: RenameFileStatus = .pending

    var fileExtension: String { originalURL.pathExtension.lowercased() }

    enum RenameFileStatus: Equatable {
        case pending
        case renamed
        case collision
        case error(String)
    }
}

struct RenameFolder {
    let url: URL
    var discoveredFiles: [RenameFileEntry] = []

    var name: String { url.lastPathComponent }
}

// MARK: - Metadata Model

struct MetadataFile: Identifiable {
    let id = UUID()
    let url: URL
    var metadata: VideoMetadata?
    var fileSize: Int64?
    var isLoading: Bool = true

    var filename: String { url.lastPathComponent }
    var path: String { url.path }
}

/// Extended metadata fields parsed from ffprobe
struct ExtendedVideoMetadata {
    var pixelFormat: String?
    var codecProfile: String?
    var colorSpace: String?
    var bitDepth: Int?
    var audioBitRate: Int?
}
