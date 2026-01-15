import Foundation
import SwiftUI

enum ToolMode: String, CaseIterable, Identifiable {
    case split = "Split Video"
    case separate = "Separate Audio/Video"
    case gif = "Create GIF"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .split: return "scissors"
        case .separate: return "arrow.triangle.branch"
        case .gif: return "photo.on.rectangle"
        }
    }
    
    var description: String {
        switch self {
        case .split: return "Split videos into segments by duration or count"
        case .separate: return "Extract video and audio streams into separate files"
        case .gif: return "Convert video clips to animated GIFs"
        }
    }
}

enum SplitMethod: String, CaseIterable, Identifiable {
    case duration = "By Duration"
    case segments = "By Segment Count"
    
    var id: String { rawValue }
}

enum FPSMode: String, CaseIterable, Identifiable {
    case single = "Same for All"
    case perFile = "Per File"
    
    var id: String { rawValue }
}

enum SampleRateMode: String, CaseIterable, Identifiable {
    case single = "Same for All"
    case perFile = "Per File"
    
    var id: String { rawValue }
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
