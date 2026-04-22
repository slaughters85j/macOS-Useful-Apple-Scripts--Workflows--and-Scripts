import Foundation
import AVFoundation

// MARK: - SplitEncoderSettings

/// Pure builders for AVFoundation `AVAssetWriterInput` output-settings
/// dictionaries used by the native splitter's re-encode path.
///
/// This namespace encodes the user-approved quality-slider semantics for the
/// native port:
///
/// - HEVC + quality mode uses VideoToolbox's constant-quality path via
///   `kVTCompressionPropertyKey_Quality` / `AVVideoQualityKey`. This mirrors
///   the legacy ffmpeg `-q:v` behavior on `hevc_videotoolbox` and gives the
///   same "lock quality, let size float" feel.
///
/// - H.264 + quality mode uses `AVVideoAverageBitRateKey`. The H.264
///   VideoToolbox encoder does NOT accept `AVVideoQualityKey`, so quality
///   must be expressed as a bitrate target. The slider is mapped onto the
///   source bitrate as a multiplier (slider/50 -> multiplier around source).
///
/// - Either codec + match-bitrate mode uses `AVVideoAverageBitRateKey` set
///   directly to the source bitrate. Consistent across codecs.
///
/// All values are clamped to sane ranges so a malformed slider (say 0 or
/// 10_000) can't produce a negative or absurd bitrate target.
///
/// Everything here is a pure static function. No I/O, no state.
enum SplitEncoderSettings {

    // MARK: - Public API

    /// Build the `outputSettings` dictionary for an `AVAssetWriterInput` that
    /// will encode video for one segment.
    ///
    /// - Parameters:
    ///   - codec: `.h264` or `.hevc`. Callers must handle `.copy` separately
    ///            by routing through the passthrough exporter instead of this
    ///            builder; passing `.copy` here returns an empty dictionary,
    ///            which is still a valid "no compression settings" dict for
    ///            `AVAssetWriterInput` but is almost certainly a caller bug.
    ///   - qualityMode: `.quality` (VBR / constant quality) or `.matchBitrate`.
    ///   - qualitySlider: UI slider value in `[1, 100]`. Higher is better.
    ///   - sourceBitrate: Estimated source video bitrate in bits per second,
    ///                    taken from `AVAssetTrack.estimatedDataRate`. Used
    ///                    directly for match-bitrate mode and as a reference
    ///                    for the H.264 quality-slider mapping.
    ///   - width: Output width in pixels. Used for `AVVideoWidthKey`.
    ///   - height: Output height in pixels. Used for `AVVideoHeightKey`.
    /// - Returns: A dictionary suitable for `AVAssetWriterInput(mediaType:
    ///            .video, outputSettings: ...)`. The dictionary is not
    ///            `Sendable`; call this on the actor that owns the writer.
    static func videoOutputSettings(
        codec: OutputCodec,
        qualityMode: QualityMode,
        qualitySlider: Double,
        sourceBitrate: Int,
        width: Int,
        height: Int
    ) -> [String: Any] {

        // Clamp the slider into the documented [1, 100] range so the derived
        // multiplier can't go negative or explode.
        let slider = max(1.0, min(100.0, qualitySlider))

        // Build the codec-specific AVVideoCompressionPropertiesKey payload.
        var compression: [String: Any] = [:]

        switch (codec, qualityMode) {

        case (.hevc, .quality):
            // HEVC + quality: use AVVideoQualityKey in [0.0, 1.0].
            // Slider is 1..100; divide by 100. Stored as NSNumber/Float.
            let quality = Float(slider / 100.0)
            compression[AVVideoQualityKey] = quality

        case (.h264, .quality):
            // H.264 + quality: no AVVideoQualityKey support on the H.264
            // VideoToolbox encoder. Map the slider onto a bitrate target
            // as a multiplier of source bitrate. Slider=50 -> ~source;
            // slider=100 -> 2x source; slider=1 -> ~2% of source.
            let target = bitrateTargetForH264Quality(
                slider: slider,
                sourceBitrate: sourceBitrate,
                width: width,
                height: height
            )
            compression[AVVideoAverageBitRateKey] = target

        case (_, .matchBitrate):
            // Either codec + match-bitrate: emit source bitrate directly.
            // Guard against a zero/negative estimate by falling back to a
            // pixel-based heuristic so the writer always gets a valid target.
            let target = (sourceBitrate > 0)
                ? sourceBitrate
                : pixelBasedBitrateFallback(width: width, height: height)
            compression[AVVideoAverageBitRateKey] = target

        case (.copy, _):
            // Caller bug: passthrough should not route through this builder.
            // Return an empty dict so the writer accepts it but the segment
            // will be visibly unencoded if this ever ships.
            return [:]
        }

        // Assemble the top-level settings dict.
        let codecType: AVVideoCodecType = (codec == .hevc) ? .hevc : .h264

        return [
            AVVideoCodecKey: codecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression
        ]
    } // videoOutputSettings

    // MARK: - Internal helpers

    /// Map a `[1, 100]` quality slider onto an H.264 bitrate target, anchored
    /// to the source bitrate.
    ///
    /// Slider at 50 yields approximately the source bitrate. Above 50 scales
    /// up linearly to 2x source at slider=100. Below 50 scales down linearly
    /// toward 2% of source at slider=1. If `sourceBitrate` is not usable, we
    /// fall back to a pixel-based floor so the writer always gets something.
    static func bitrateTargetForH264Quality(
        slider: Double,
        sourceBitrate: Int,
        width: Int,
        height: Int
    ) -> Int {
        let multiplier = max(0.02, slider / 50.0)
        let anchor = (sourceBitrate > 0)
            ? Double(sourceBitrate)
            : Double(pixelBasedBitrateFallback(width: width, height: height))
        let target = anchor * multiplier

        // Don't let the final target collapse below a reasonable floor; a
        // 100 kbps floor keeps AVAssetWriter happy on any realistic clip.
        return max(100_000, Int(target))
    } // bitrateTargetForH264Quality

    /// Compute a default bitrate when the source bitrate is unknown, based
    /// purely on output pixel area. Roughly 0.1 bits per pixel per second at
    /// 30 fps. Coarse, but only used as a fallback.
    static func pixelBasedBitrateFallback(width: Int, height: Int) -> Int {
        let pixels = max(1, width) * max(1, height)
        // bits/pixel/frame * frames/sec = bits/pixel/sec
        let bitsPerPixelPerSecond = 0.1 * 30.0
        let target = Double(pixels) * bitsPerPixelPerSecond
        return max(500_000, Int(target))
    } // pixelBasedBitrateFallback
} // SplitEncoderSettings

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SplitEncoderSettings`.
/// Call `SplitEncoderSettingsTests.runAll()` from a scratch entry point
/// under `#if DEBUG` to exercise the pure mapping logic.
enum SplitEncoderSettingsTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
            } else {
                failed.append(name)
            }
        } // check

        // Dig out AVVideoAverageBitRateKey from a settings dict's compression
        // sub-dict. Returns nil if any link is missing. Keeps the assertions
        // below short and avoids multi-line optional-chain parsing hazards.
        func bitrate(_ settings: [String: Any]) -> Int? {
            let comp = settings[AVVideoCompressionPropertiesKey] as? [String: Any]
            return comp?[AVVideoAverageBitRateKey] as? Int
        } // bitrate

        // MARK: HEVC quality mode

        let hevcQuality = SplitEncoderSettings.videoOutputSettings(
            codec: .hevc,
            qualityMode: .quality,
            qualitySlider: 75,
            sourceBitrate: 10_000_000,
            width: 1920,
            height: 1080
        )
        let hevcCodec = hevcQuality[AVVideoCodecKey] as? AVVideoCodecType
        let hevcComp = hevcQuality[AVVideoCompressionPropertiesKey] as? [String: Any]
        let hevcQValue = hevcComp?[AVVideoQualityKey] as? Float
        check("HEVC quality uses AVVideoCodecType.hevc", hevcCodec == .hevc)
        check("HEVC quality populates AVVideoQualityKey", hevcQValue != nil)
        check("HEVC quality key is in [0.0, 1.0]",
              hevcQValue.map { $0 >= 0.0 && $0 <= 1.0 } ?? false)
        check("HEVC quality slider 75 -> 0.75",
              hevcQValue.map { abs($0 - 0.75) < 1e-6 } ?? false)
        check("HEVC settings set width/height",
              (hevcQuality[AVVideoWidthKey] as? Int) == 1920 &&
              (hevcQuality[AVVideoHeightKey] as? Int) == 1080)

        // MARK: HEVC quality clamping

        let hevcOver = SplitEncoderSettings.videoOutputSettings(
            codec: .hevc, qualityMode: .quality, qualitySlider: 500,
            sourceBitrate: 5_000_000, width: 1280, height: 720
        )
        let hevcOverComp = hevcOver[AVVideoCompressionPropertiesKey] as? [String: Any]
        let hevcOverQ = hevcOverComp?[AVVideoQualityKey] as? Float
        check("HEVC slider over 100 clamps to 1.0",
              hevcOverQ.map { abs($0 - 1.0) < 1e-6 } ?? false)

        let hevcUnder = SplitEncoderSettings.videoOutputSettings(
            codec: .hevc, qualityMode: .quality, qualitySlider: -5,
            sourceBitrate: 5_000_000, width: 1280, height: 720
        )
        let hevcUnderComp = hevcUnder[AVVideoCompressionPropertiesKey] as? [String: Any]
        let hevcUnderQ = hevcUnderComp?[AVVideoQualityKey] as? Float
        check("HEVC slider under 1 clamps to 0.01",
              hevcUnderQ.map { abs($0 - 0.01) < 1e-6 } ?? false)

        // MARK: H.264 quality mode uses bitrate, not quality key

        let h264Quality = SplitEncoderSettings.videoOutputSettings(
            codec: .h264,
            qualityMode: .quality,
            qualitySlider: 50,
            sourceBitrate: 8_000_000,
            width: 1920,
            height: 1080
        )
        let h264Codec = h264Quality[AVVideoCodecKey] as? AVVideoCodecType
        let h264Comp = h264Quality[AVVideoCompressionPropertiesKey] as? [String: Any]
        let h264Bitrate = h264Comp?[AVVideoAverageBitRateKey] as? Int
        let h264QKey = h264Comp?[AVVideoQualityKey]
        check("H.264 quality uses AVVideoCodecType.h264", h264Codec == .h264)
        check("H.264 quality does NOT set AVVideoQualityKey", h264QKey == nil)
        check("H.264 quality sets AVVideoAverageBitRateKey", h264Bitrate != nil)
        check("H.264 slider=50 gives ~source bitrate",
              h264Bitrate.map { abs($0 - 8_000_000) < 1000 } ?? false)

        // MARK: H.264 quality scaling

        let h264High = SplitEncoderSettings.videoOutputSettings(
            codec: .h264, qualityMode: .quality, qualitySlider: 100,
            sourceBitrate: 5_000_000, width: 1280, height: 720
        )
        let h264HighBitrate = bitrate(h264High)
        check("H.264 slider=100 -> ~2x source",
              h264HighBitrate.map { abs($0 - 10_000_000) < 1000 } ?? false)

        let h264Low = SplitEncoderSettings.videoOutputSettings(
            codec: .h264, qualityMode: .quality, qualitySlider: 1,
            sourceBitrate: 5_000_000, width: 1280, height: 720
        )
        let h264LowBitrate = bitrate(h264Low)
        check("H.264 slider=1 respects 100 kbps floor",
              h264LowBitrate.map { $0 >= 100_000 } ?? false)

        // MARK: Match-bitrate mode

        let matchHevc = SplitEncoderSettings.videoOutputSettings(
            codec: .hevc, qualityMode: .matchBitrate, qualitySlider: 50,
            sourceBitrate: 6_000_000, width: 1920, height: 1080
        )
        check("match-bitrate HEVC copies source bitrate",
              bitrate(matchHevc) == 6_000_000)

        let matchH264 = SplitEncoderSettings.videoOutputSettings(
            codec: .h264, qualityMode: .matchBitrate, qualitySlider: 50,
            sourceBitrate: 4_500_000, width: 1280, height: 720
        )
        check("match-bitrate H.264 copies source bitrate",
              bitrate(matchH264) == 4_500_000)

        // MARK: Match-bitrate with zero source bitrate falls back to pixel heuristic

        let matchZero = SplitEncoderSettings.videoOutputSettings(
            codec: .hevc, qualityMode: .matchBitrate, qualitySlider: 50,
            sourceBitrate: 0, width: 1920, height: 1080
        )
        check("match-bitrate with zero source falls back to pixel heuristic",
              bitrate(matchZero).map { $0 > 0 } ?? false)

        // MARK: Pixel-based fallback respects floor

        let tiny = SplitEncoderSettings.pixelBasedBitrateFallback(width: 1, height: 1)
        check("pixel fallback respects 500 kbps floor", tiny >= 500_000)

        let hd = SplitEncoderSettings.pixelBasedBitrateFallback(width: 1920, height: 1080)
        check("pixel fallback for 1080p is in a sane range",
              hd > 1_000_000 && hd < 50_000_000)

        // MARK: Copy codec guard

        let copyDict = SplitEncoderSettings.videoOutputSettings(
            codec: .copy, qualityMode: .quality, qualitySlider: 50,
            sourceBitrate: 5_000_000, width: 1280, height: 720
        )
        check("codec=.copy returns empty dict (caller bug guard)", copyDict.isEmpty)

        print("SplitEncoderSettingsTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SplitEncoderSettingsTests

#endif
