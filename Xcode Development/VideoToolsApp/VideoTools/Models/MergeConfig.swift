import Foundation

// MARK: - MergeConfig

/// Configuration for a native batch video-merge operation.
///
/// Parallel of `SplitConfig` and `GifRenderConfig` for the merger. Internal
/// value type, never serialized (the legacy `MergerConfig` Codable type
/// that it replaces shipped to Python via JSON; this one stays in-process).
/// Consumed by `VideoMerger`.
///
/// The file naming follows the splitter convention: `MergeConfig` for the
/// native type, contrasted with the now-removed `MergerConfig` Codable that
/// lived alongside the Python path.
struct MergeConfig: Sendable {

    // MARK: - Inputs

    /// Source video URLs, in the batch order the user arranged them in the
    /// UI. The output plays these back-to-back on a single timeline.
    let inputs: [URL]

    // MARK: - Output

    /// Final filename (without directory). The merger appends the source
    /// extension of `inputs[0]` when the user hasn't specified one; the
    /// builder on `AppState` handles that defaulting.
    let outputFilename: String

    /// Directory the output file is written to. Resolved from the user's
    /// `MergeOutputLocation` choice (first-file parent or custom picker).
    let outputDirectory: URL

    // MARK: - Encoding

    /// Aspect-mode policy when inputs have heterogeneous display sizes in
    /// re-encode mode. Ignored when `codec == .copy` (copy path refuses
    /// heterogeneous inputs outright).
    let aspectMode: MergeAspectMode

    /// Output codec. `.copy` routes through `MergePassthroughExporter`;
    /// `.h264` and `.hevc` route through `MergeReencodeExporter`.
    let codec: OutputCodec

    /// Quality mode. Ignored for `.copy`. For `.quality`, the slider drives
    /// `AVVideoQualityKey` on HEVC and an `AVVideoAverageBitRateKey` target
    /// on H.264 (same semantics as the splitter, see `SplitEncoderSettings`).
    /// For `.matchBitrate`, the max source bitrate across inputs is used.
    let qualityMode: QualityMode

    /// Quality slider value in `[1, 100]`. Higher is better. Ignored when
    /// `qualityMode == .matchBitrate` or `codec == .copy`.
    let qualityValue: Double

    /// Target output frame rate in re-encode mode, applied via
    /// `AVVideoComposition.frameDuration`. Ignored when `codec == .copy`.
    let frameRate: Double

    // MARK: - Init

    init(
        inputs: [URL],
        outputFilename: String,
        outputDirectory: URL,
        aspectMode: MergeAspectMode,
        codec: OutputCodec,
        qualityMode: QualityMode,
        qualityValue: Double,
        frameRate: Double
    ) {
        self.inputs = inputs
        self.outputFilename = outputFilename
        self.outputDirectory = outputDirectory
        self.aspectMode = aspectMode
        self.codec = codec
        self.qualityMode = qualityMode
        self.qualityValue = qualityValue
        self.frameRate = frameRate
    } // init

    // MARK: - Helpers

    /// The resolved output URL, combining `outputDirectory` with
    /// `outputFilename` and falling back to the first input's extension if
    /// the filename has none (e.g. the user typed "merged_output").
    var outputURL: URL {
        let ext = URL(fileURLWithPath: outputFilename).pathExtension
        if !ext.isEmpty {
            return outputDirectory.appendingPathComponent(outputFilename)
        }
        let fallbackExt = inputs.first?.pathExtension ?? "mp4"
        return outputDirectory
            .appendingPathComponent(outputFilename)
            .appendingPathExtension(fallbackExt)
    } // outputURL
} // MergeConfig

// MARK: - Validation

extension MergeConfig {

    /// Returns a human-readable validation error, or `nil` if the config is
    /// sound. Checked by `VideoMerger.merge` before any probe work begins.
    var validationError: String? {
        if inputs.count < 2 {
            return "Merging requires at least two input videos."
        }
        if outputFilename.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Output filename is empty."
        }
        if qualityMode == .quality, codec != .copy {
            if qualityValue < 1 || qualityValue > 100 {
                return "qualityValue must be in [1, 100], got \(qualityValue)"
            }
        }
        if codec != .copy, frameRate <= 0 {
            return "frameRate must be greater than 0 in re-encode mode, got \(frameRate)"
        }
        return nil
    } // validationError
} // MergeConfig extension

// MARK: - AppState -> MergeConfig Builder

extension AppState {

    /// Build a `MergeConfig` from the current AppState for the native merger.
    ///
    /// Mirrors `buildGifRenderConfig()` and `buildSplitConfig()`. Output
    /// directory resolution follows the legacy rule: custom picker when set,
    /// otherwise the parent directory of the first input file.
    @MainActor
    func buildMergeConfig() -> MergeConfig {
        let outputDirectory: URL = {
            if mergeOutputLocation == .custom, let customDir = mergeCustomOutputDir {
                return customDir
            }
            if let first = videoFiles.first {
                return first.url.deletingLastPathComponent()
            }
            return URL(fileURLWithPath: ".")
        }()

        return MergeConfig(
            inputs: videoFiles.map(\.url),
            outputFilename: mergeOutputFilename,
            outputDirectory: outputDirectory,
            aspectMode: mergeAspectMode,
            codec: mergeOutputCodec,
            qualityMode: mergeQualityMode,
            qualityValue: mergeQualityValue,
            frameRate: mergeFpsValue
        )
    } // buildMergeConfig
} // AppState extension

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `MergeConfig`.
enum MergeConfigTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        let a = URL(fileURLWithPath: "/tmp/a.mp4")
        let b = URL(fileURLWithPath: "/tmp/b.mp4")
        let dir = URL(fileURLWithPath: "/tmp")

        // MARK: Baseline valid

        let baseline = MergeConfig(
            inputs: [a, b],
            outputFilename: "out.mp4",
            outputDirectory: dir,
            aspectMode: .letterbox,
            codec: .h264,
            qualityMode: .quality,
            qualityValue: 65,
            frameRate: 30
        )
        check("baseline valid", baseline.validationError == nil)

        // MARK: Too few inputs

        let solo = MergeConfig(
            inputs: [a], outputFilename: "out.mp4", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 50, frameRate: 30
        )
        check("single input rejected", solo.validationError != nil)

        // MARK: Empty filename

        let blank = MergeConfig(
            inputs: [a, b], outputFilename: "  ", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 50, frameRate: 30
        )
        check("blank filename rejected", blank.validationError != nil)

        // MARK: Quality out of range (re-encode only)

        let badQuality = MergeConfig(
            inputs: [a, b], outputFilename: "out.mp4", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 500, frameRate: 30
        )
        check("quality 500 rejected for re-encode",
              badQuality.validationError != nil)

        // Same out-of-range slider is ignored for copy codec
        let copyIgnores = MergeConfig(
            inputs: [a, b], outputFilename: "out.mp4", outputDirectory: dir,
            aspectMode: .letterbox, codec: .copy,
            qualityMode: .quality, qualityValue: 500, frameRate: 30
        )
        check("copy codec ignores out-of-range quality",
              copyIgnores.validationError == nil)

        // MARK: fps <= 0 in re-encode mode

        let badFps = MergeConfig(
            inputs: [a, b], outputFilename: "out.mp4", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 50, frameRate: 0
        )
        check("fps=0 rejected in re-encode", badFps.validationError != nil)

        // fps=0 is fine in copy mode (unused)
        let copyZeroFps = MergeConfig(
            inputs: [a, b], outputFilename: "out.mp4", outputDirectory: dir,
            aspectMode: .letterbox, codec: .copy,
            qualityMode: .quality, qualityValue: 50, frameRate: 0
        )
        check("fps=0 fine in copy", copyZeroFps.validationError == nil)

        // MARK: outputURL appends source extension when user omits one

        let noExt = MergeConfig(
            inputs: [a, b], outputFilename: "out", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 50, frameRate: 30
        )
        check("missing extension falls back to first input's",
              noExt.outputURL.lastPathComponent == "out.mp4")

        let hasExt = MergeConfig(
            inputs: [a, b], outputFilename: "out.mov", outputDirectory: dir,
            aspectMode: .letterbox, codec: .h264,
            qualityMode: .quality, qualityValue: 50, frameRate: 30
        )
        check("explicit extension preserved",
              hasExt.outputURL.lastPathComponent == "out.mov")

        print("MergeConfigTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // MergeConfigTests

#endif
