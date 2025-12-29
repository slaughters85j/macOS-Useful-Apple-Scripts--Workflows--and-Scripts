import Foundation
import SwiftUI

enum ToolMode: String, CaseIterable, Identifiable {
    case split = "Split Video"
    case separate = "Separate Audio/Video"
    
    var id: String { rawValue }
    
    var icon: String {
        switch self {
        case .split: return "scissors"
        case .separate: return "arrow.triangle.branch"
        }
    }
    
    var description: String {
        switch self {
        case .split: return "Split videos into segments by duration or count"
        case .separate: return "Extract video and audio streams into separate files"
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

struct VideoFile: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    var customFPS: Double?
    var customSampleRate: SampleRate?
    var metadata: VideoMetadata?
    
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
