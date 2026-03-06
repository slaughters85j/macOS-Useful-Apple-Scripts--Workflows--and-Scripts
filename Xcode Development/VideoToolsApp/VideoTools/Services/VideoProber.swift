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

    // Extended fields
    let pixelFormat: String?
    let codecProfile: String?
    let colorSpace: String?
    let bitDepth: Int?
    let audioBitRate: Int?

    var resolution: String { "\(width)×\(height)" }
    var aspectRatio: String {
        guard width > 0, height > 0 else { return "N/A" }
        let gcd = gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }
    var durationFormatted: String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        let ms = Int((duration - Double(Int(duration))) * 100)
        if hours > 0 {
            return String(format: "%d:%02d:%02d.%02d", hours, minutes, seconds, ms)
        }
        return String(format: "%d:%02d.%02d", minutes, seconds, ms)
    }
    var bitRateMbps: String { String(format: "%.2f Mbps", Double(bitRate) / 1_000_000) }
    var frameRateFormatted: String { String(format: "%.2f fps", frameRate) }
    var audioSampleRateFormatted: String? {
        guard let rate = audioSampleRate else { return nil }
        return "\(rate) Hz"
    }
    var audioChannelsFormatted: String? {
        guard let ch = audioChannels else { return nil }
        switch ch {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1 Surround"
        case 8: return "7.1 Surround"
        default: return "\(ch) channels"
        }
    }
    var audioBitRateFormatted: String? {
        guard let abr = audioBitRate else { return nil }
        return "\(abr / 1000) kbps"
    }

    private func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? a : gcd(b, a % b)
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
        
        // Parse extended fields
        let pixelFormat = videoStream["pix_fmt"] as? String
        let codecProfile = videoStream["profile"] as? String
        let colorSpace = videoStream["color_space"] as? String
        let bitDepth = videoStream["bits_per_raw_sample"] as? String
        var audioBitRate: Int?
        if let audio = audioStream,
           let abr = audio["bit_rate"] as? String {
            audioBitRate = Int(abr)
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
            audioCodec: audioCodec,
            pixelFormat: pixelFormat,
            codecProfile: codecProfile,
            colorSpace: colorSpace,
            bitDepth: bitDepth.flatMap { Int($0) },
            audioBitRate: audioBitRate
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
