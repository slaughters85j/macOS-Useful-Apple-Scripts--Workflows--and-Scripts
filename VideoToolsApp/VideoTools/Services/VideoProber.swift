import Foundation

struct VideoMetadata: Sendable {
    let duration: Double
    let frameRate: Double
    let bitRate: Int
    let width: Int
    let height: Int
    let videoCodec: String
    let hasAudio: Bool
    let audioSampleRate: Int?
    let audioChannels: Int?
    let audioCodec: String?
    
    var resolution: String { "\(width)×\(height)" }
    var durationFormatted: String { 
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    var bitRateMbps: String { String(format: "%.2f Mbps", Double(bitRate) / 1_000_000) }
    var frameRateFormatted: String { String(format: "%.2f fps", frameRate) }
    var audioSampleRateFormatted: String? {
        guard let rate = audioSampleRate else { return nil }
        return "\(rate) Hz"
    }
}

actor VideoProber {
    
    private let ffprobePath: String
    
    init() {
        // Find ffprobe
        let candidates = [
            "/usr/local/bin/ffprobe",
            "/opt/homebrew/bin/ffprobe",
            "/usr/bin/ffprobe"
        ]
        ffprobePath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "ffprobe"
        print("VideoProber: Using ffprobe at: \(ffprobePath)")
    }
    
    func probe(url: URL) async -> VideoMetadata? {
        // Verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("VideoProber: File does not exist at path: \(url.path)")
            return nil
        }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]
        
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            // Check exit status
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown error"
                print("VideoProber: ffprobe exited with status \(process.terminationStatus): \(errorString)")
                return nil
            }
            
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            
            // Check if we got any data
            guard !data.isEmpty else {
                print("VideoProber: No data received from ffprobe")
                return nil
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("VideoProber: Failed to parse JSON. Data: \(String(data: data.prefix(200), encoding: .utf8) ?? "invalid")")
                return nil
            }
            
            return parseProbeOutput(json)
        } catch {
            print("VideoProber: Process execution failed: \(error)")
            return nil
        }
    }
    
    private func parseProbeOutput(_ json: [String: Any]) -> VideoMetadata? {
        guard let streams = json["streams"] as? [[String: Any]],
              let format = json["format"] as? [String: Any] else {
            print("VideoProber: Missing streams or format in JSON")
            return nil
        }
        
        // Find video stream
        guard let videoStream = streams.first(where: { ($0["codec_type"] as? String) == "video" }) else {
            print("VideoProber: No video stream found")
            return nil
        }
        
        // Find audio stream (optional)
        let audioStream = streams.first { ($0["codec_type"] as? String) == "audio" }
        
        // Parse frame rate
        let fpsString = videoStream["avg_frame_rate"] as? String ?? "30/1"
        let frameRate = parseFrameRate(fpsString)
        
        // Parse bit rate (try video stream, then format)
        let bitRate: Int
        if let br = videoStream["bit_rate"] as? String, let parsed = Int(br) {
            bitRate = parsed
        } else if let br = format["bit_rate"] as? String, let parsed = Int(br) {
            bitRate = parsed
        } else {
            bitRate = 2_000_000
        }
        
        // Parse duration
        let duration: Double
        if let dur = format["duration"] as? String, let parsed = Double(dur) {
            duration = parsed
        } else {
            duration = 0
        }
        
        // Parse audio info
        var audioSampleRate: Int?
        var audioChannels: Int?
        var audioCodec: String?
        
        if let audio = audioStream {
            if let sr = audio["sample_rate"] as? String {
                audioSampleRate = Int(sr)
            }
            audioChannels = audio["channels"] as? Int
            audioCodec = audio["codec_name"] as? String
        }
        
        let metadata = VideoMetadata(
            duration: duration,
            frameRate: frameRate,
            bitRate: bitRate,
            width: videoStream["width"] as? Int ?? 0,
            height: videoStream["height"] as? Int ?? 0,
            videoCodec: videoStream["codec_name"] as? String ?? "unknown",
            hasAudio: audioStream != nil,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels,
            audioCodec: audioCodec
        )
        print("VideoProber: Successfully parsed metadata - \(metadata.resolution), \(metadata.durationFormatted), \(metadata.frameRateFormatted)")
        return metadata
    }
    
    private func parseFrameRate(_ fpsString: String) -> Double {
        if fpsString.contains("/") {
            let parts = fpsString.split(separator: "/")
            if parts.count == 2,
               let num = Double(parts[0]),
               let den = Double(parts[1]),
               den > 0 {
                return num / den
            }
        }
        return Double(fpsString) ?? 30.0
    }
}
