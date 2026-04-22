import Foundation
import AVFoundation
import CoreMedia

// MARK: - VideoMetadata

/// Snapshot of a video file's metadata, populated by `VideoProber`.
///
/// Shape preserved from the previous ffprobe-backed implementation so the
/// UI's metadata inspector (`MetadataSettingsView`) and the per-file probe
/// cache (`AppState.probeNewFiles`) keep working without changes. Field
/// semantics match ffprobe's `codec_name`, `pix_fmt`, `color_space`, and
/// `bits_per_raw_sample` conventions where possible.
///
/// The three "extended" fields (pixelFormat, colorSpace, bitDepth) are
/// **best-effort** from `CMFormatDescription` extensions. Common codecs
/// (H.264, HEVC, ProRes) populate them; exotic codecs may leave them nil
/// and the UI renders a dash.
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

    // Extended fields (best-effort native extraction)
    let pixelFormat: String?
    let codecProfile: String?
    let colorSpace: String?
    let bitDepth: Int?
    let audioBitRate: Int?

    // MARK: - Display helpers

    var resolution: String { "\(width)×\(height)" }
    var aspectRatio: String {
        guard width > 0, height > 0 else { return "N/A" }
        let g = gcd(width, height)
        return "\(width / g):\(height / g)"
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
    var bitRateMbps: String {
        String(format: "%.2f Mbps", Double(bitRate) / 1_000_000)
    }
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
} // VideoMetadata

// MARK: - VideoProber

/// Native AVFoundation-based metadata prober.
///
/// Public signature preserved from the previous ffprobe-backed implementation
/// (`probe(url:) async -> VideoMetadata?`) so existing call sites
/// (`AppState.probeNewFiles`, `AppState.loadMetadata`) keep working without
/// changes. Returns `nil` on unreadable files or assets without a video
/// track; never throws.
///
/// ### Best-effort extended fields
///
/// `pixelFormat`, `colorSpace`, and `bitDepth` come from
/// `CMFormatDescriptionGetExtensions()`. For H.264 and HEVC the values are
/// typically populated; for exotic codecs they may be nil, which the UI
/// renders as a dash. This is the documented trade-off for dropping the
/// ffprobe runtime dependency.
actor VideoProber {

    init() {}

    // MARK: - Public API

    /// Probe a video file at `url` and return its metadata, or `nil` on
    /// any failure (file missing, no video track, load errors).
    ///
    /// Never throws; errors are logged to the console and surfaced to the
    /// UI as a generic "could not read metadata" state.
    func probe(url: URL) async -> VideoMetadata? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("VideoProber: File does not exist at path: \(url.path)")
            return nil
        }

        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration).seconds

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                print("VideoProber: No video track in \(url.lastPathComponent)")
                return nil
            }

            let naturalSize = try await videoTrack.load(.naturalSize)
            let nominalFPS = try await videoTrack.load(.nominalFrameRate)
            let estimatedBitrate = Int(try await videoTrack.load(.estimatedDataRate))
            let formatDescriptions = try await videoTrack.load(.formatDescriptions)

            // Size can be negative after preferredTransform application in
            // some edge cases; we use the abs/ceil treatment like the rest
            // of the app.
            let width = Int(abs(naturalSize.width))
            let height = Int(abs(naturalSize.height))

            let videoFormatDescription = formatDescriptions.first

            let videoCodec: String = videoFormatDescription.map {
                CodecNameResolver.name(forFourCC: CMFormatDescriptionGetMediaSubType($0))
            } ?? "unknown"

            let extensions = videoFormatDescription
                .flatMap { CMFormatDescriptionGetExtensions($0) as? [String: Any] }
                ?? [:]

            let pixelFormat: String? = extractPixelFormat(
                description: videoFormatDescription, extensions: extensions
            )
            let colorSpace: String? = extractColorSpace(extensions: extensions)
            let bitDepth: Int? = extractBitDepth(
                extensions: extensions, pixelFormat: pixelFormat
            )
            let codecProfile: String? = extractCodecProfile(extensions: extensions)

            // MARK: Audio
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var hasAudio = false
            var audioSampleRate: Int?
            var audioChannels: Int?
            var audioCodec: String?
            var audioBitRate: Int?

            if let audioTrack = audioTracks.first {
                hasAudio = true
                let audioFormatDescriptions = try await audioTrack.load(.formatDescriptions)
                if let audioFD = audioFormatDescriptions.first {
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFD)?.pointee {
                        audioSampleRate = asbd.mSampleRate > 0 ? Int(asbd.mSampleRate) : nil
                        audioChannels = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
                    }
                    audioCodec = CodecNameResolver.name(
                        forFourCC: CMFormatDescriptionGetMediaSubType(audioFD)
                    )
                }
                let audioRate = try await audioTrack.load(.estimatedDataRate)
                if audioRate > 0 {
                    audioBitRate = Int(audioRate)
                }
            }

            let metadata = VideoMetadata(
                duration: duration,
                frameRate: Double(nominalFPS),
                bitRate: estimatedBitrate,
                width: width,
                height: height,
                videoCodec: videoCodec,
                hasAudio: hasAudio,
                audioSampleRate: audioSampleRate,
                audioChannels: audioChannels,
                audioCodec: audioCodec,
                pixelFormat: pixelFormat,
                codecProfile: codecProfile,
                colorSpace: colorSpace,
                bitDepth: bitDepth,
                audioBitRate: audioBitRate
            )
            print("VideoProber: Probed \(url.lastPathComponent) — \(metadata.resolution), \(metadata.durationFormatted), \(metadata.frameRateFormatted)")
            return metadata
        } catch {
            print("VideoProber: Probe failed for \(url.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    } // probe

    // MARK: - Best-effort extension extractors

    /// Pull a pixel-format string from the video format description.
    ///
    /// `CMFormatDescriptionGetMediaSubType` on a video description returns
    /// the codec FourCC (avc1 etc.), NOT the pixel format. The actual pixel
    /// format comes from `CVPixelBuffer`-attached buffers, or from the
    /// `kCMFormatDescriptionExtension_BitsPerComponent` +
    /// `kCVImageBufferChromaSubsamplingKey` pair carried in extensions.
    ///
    /// For most compressed sources the pixel format isn't directly
    /// encoded at the CMFormatDescription level; we infer a reasonable
    /// label from chroma-subsampling + bit-depth when available, else nil.
    private nonisolated func extractPixelFormat(
        description: CMFormatDescription?,
        extensions: [String: Any]
    ) -> String? {
        // Look for pixel format in extensions directly (some codecs / containers
        // populate this).
        if let explicit = extensions[kCMFormatDescriptionExtension_FormatName as String] as? String,
           !explicit.isEmpty {
            return explicit.lowercased()
        }

        // Infer from chroma subsampling + bit depth extensions, if present.
        let chroma = extensions[kCVImageBufferChromaSubsamplingKey as String] as? String
        let bitsPerComponent = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int

        switch (chroma, bitsPerComponent) {
        case ("4:2:0", 8?):  return "yuv420p"
        case ("4:2:0", 10?): return "yuv420p10le"
        case ("4:2:2", 8?):  return "yuv422p"
        case ("4:2:2", 10?): return "yuv422p10le"
        case ("4:4:4", 8?):  return "yuv444p"
        case ("4:4:4", 10?): return "yuv444p10le"
        case ("4:2:0", nil): return "yuv420p"
        case ("4:2:2", nil): return "yuv422p"
        case ("4:4:4", nil): return "yuv444p"
        default:
            return nil
        }
    } // extractPixelFormat

    /// Pull a color-space string from the extensions dict.
    ///
    /// Matches against common `kCVImageBufferYCbCrMatrix_*` constants to
    /// produce ffprobe-compatible names like "bt709", "bt2020nc", "smpte170m".
    private nonisolated func extractColorSpace(
        extensions: [String: Any]
    ) -> String? {
        let matrixRaw = extensions[kCVImageBufferYCbCrMatrixKey as String] as? String

        guard let matrix = matrixRaw else { return nil }

        // Compare via CFEqual-style string matching. The CoreVideo constants
        // are CFStrings; their underlying text values match the suffix.
        switch matrix {
        case String(kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String):
            return "bt709"
        case String(kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String):
            return "smpte170m"
        case String(kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 as String):
            return "smpte240m"
        case String(kCVImageBufferYCbCrMatrix_ITU_R_2020 as String):
            return "bt2020nc"
        default:
            // Return the raw value lowercased rather than nil — some users
            // find this more useful than "—" for debugging unusual files.
            return matrix.lowercased()
        }
    } // extractColorSpace

    /// Extract bit depth from the extensions dict. Returns nil when the
    /// codec doesn't expose it.
    private nonisolated func extractBitDepth(
        extensions: [String: Any],
        pixelFormat: String?
    ) -> Int? {
        // Direct: kCMFormatDescriptionExtension_BitsPerComponent is an Int
        // when present.
        if let bpc = extensions[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int {
            return bpc
        }
        // Infer from the pixel-format string we computed above (e.g.
        // "yuv420p10le" implies 10-bit).
        if let pixelFormat {
            if pixelFormat.contains("10le") || pixelFormat.contains("10be") {
                return 10
            }
            if pixelFormat.contains("12le") || pixelFormat.contains("12be") {
                return 12
            }
            // Default to 8-bit when the format string exists but doesn't
            // specify.
            return 8
        }
        return nil
    } // extractBitDepth

    /// Extract codec profile string (e.g. "High", "Main 10") from
    /// extensions. Not always populated; returns nil when absent.
    private nonisolated func extractCodecProfile(
        extensions: [String: Any]
    ) -> String? {
        if let s = extensions["ProfileLevelID"] as? String, !s.isEmpty {
            return s
        }
        // H.264 / HEVC sometimes store profile in the sample description
        // extensions dict under various keys. We don't attempt exhaustive
        // parsing here; this field was already "nullable" in the old
        // ffprobe path, so nil is acceptable.
        return nil
    } // extractCodecProfile

} // VideoProber

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `VideoProber`.
/// Full correctness of best-effort extension extraction is verified by
/// running real video files through the Metadata tool UI.
enum VideoProberTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        // MARK: VideoMetadata display helpers

        let m = VideoMetadata(
            duration: 75.5,
            frameRate: 29.97,
            bitRate: 5_000_000,
            width: 1920,
            height: 1080,
            videoCodec: "h264",
            hasAudio: true,
            audioSampleRate: 48_000,
            audioChannels: 2,
            audioCodec: "aac",
            pixelFormat: "yuv420p",
            codecProfile: nil,
            colorSpace: "bt709",
            bitDepth: 8,
            audioBitRate: 192_000
        )
        check("resolution formatting", m.resolution == "1920×1080")
        check("aspect ratio 16:9", m.aspectRatio == "16:9")
        check("duration formatted",
              m.durationFormatted == "1:15.50" || m.durationFormatted == "1:15.49")
        check("bit rate in Mbps", m.bitRateMbps == "5.00 Mbps")
        check("frame rate formatted", m.frameRateFormatted == "29.97 fps")
        check("audio sample rate formatted",
              m.audioSampleRateFormatted == "48000 Hz")
        check("stereo channels formatted",
              m.audioChannelsFormatted == "Stereo")
        check("audio bit rate formatted",
              m.audioBitRateFormatted == "192 kbps")

        // MARK: GCD sanity (edge cases)
        let m2 = VideoMetadata(
            duration: 0, frameRate: 0, bitRate: 0, width: 0, height: 0,
            videoCodec: "x", hasAudio: false, audioSampleRate: nil,
            audioChannels: nil, audioCodec: nil, pixelFormat: nil,
            codecProfile: nil, colorSpace: nil, bitDepth: nil, audioBitRate: nil
        )
        check("0x0 aspect is N/A", m2.aspectRatio == "N/A")

        print("VideoProberTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // VideoProberTests

#endif
