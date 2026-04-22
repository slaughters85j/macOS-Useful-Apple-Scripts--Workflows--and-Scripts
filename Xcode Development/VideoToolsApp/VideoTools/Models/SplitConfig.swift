import Foundation

// MARK: - SplitConfig

/// Configuration for a native batch video-split operation.
///
/// Parallel of `GifRenderConfig` for the splitter. Internal value type, never
/// serialized, consumed by `VideoSplitter` and its supporting services. The
/// per-file FPS override map is keyed by filename (not full path) to match
/// the existing Python convention; the orchestrator resolves filenames against
/// `inputs` when reading per-file overrides.
struct SplitConfig: Sendable {

    // MARK: - Inputs

    /// Video file URLs to process in batch order.
    let inputs: [URL]

    // MARK: - Split strategy

    /// How to slice the source timeline into segments. Forwarded to
    /// `SplitSegmentCalculator.segmentRanges`.
    let method: SplitMethod

    /// For `.duration`, seconds per segment. For `.segments`, segment count.
    /// For `.reencodeOnly`, ignored (treated as a single full-duration
    /// segment). This is the already-unit-normalized value from
    /// `AppState.splitValueInSeconds`.
    let splitValue: Double

    // MARK: - Frame rate

    /// Global target output frame rate. Used when no per-file override is
    /// registered. A value less than or equal to zero disables fps conversion
    /// (segments inherit the source frame rate).
    let globalFrameRate: Double

    /// Per-file frame-rate overrides keyed by filename (`URL.lastPathComponent`).
    /// When a key is present, its value takes precedence over `globalFrameRate`
    /// for that input.
    let perFileFrameRate: [String: Double]

    /// When true (`FPSMode.perFile`), the orchestrator looks up each input in
    /// `perFileFrameRate` and falls back to `globalFrameRate` when absent.
    /// When false (`FPSMode.single`), only `globalFrameRate` is used.
    let usePerFileFrameRate: Bool

    // MARK: - Encoding

    /// Output codec. `.copy` routes segments through
    /// `SegmentPassthroughExporter`; `.h264` and `.hevc` route through
    /// `SegmentReencodeExporter`. Note that an fps override (when different
    /// from the source nominal fps) forces the re-encode path even when
    /// `.copy` is selected, because passthrough cannot change frame rate.
    let codec: OutputCodec

    /// Quality mode. Ignored for `.copy`. For `.quality`, the slider drives
    /// `AVVideoQualityKey` on HEVC and an `AVVideoAverageBitRateKey` target
    /// on H.264 (see `SplitEncoderSettings`). For `.matchBitrate`, the
    /// source bitrate is used directly on both codecs.
    let qualityMode: QualityMode

    /// Quality slider value in `[1, 100]`. Higher is better. Ignored when
    /// `qualityMode == .matchBitrate` or `codec == .copy`.
    let qualityValue: Double

    // MARK: - Output layout

    /// Per-file subfolder vs. alongside-source placement of output segments.
    let outputFolderMode: OutputFolderMode

    // MARK: - Parallelism

    /// Maximum concurrent segment exports per file. Honored verbatim per the
    /// user's stepper value. VideoToolbox encoder throughput is ultimately
    /// governed by the OS, so large values may not yield proportional speedup
    /// on Apple Silicon; this is not clamped here.
    let parallelJobs: Int

    // MARK: - Init

    init(
        inputs: [URL],
        method: SplitMethod,
        splitValue: Double,
        globalFrameRate: Double,
        perFileFrameRate: [String: Double],
        usePerFileFrameRate: Bool,
        codec: OutputCodec,
        qualityMode: QualityMode,
        qualityValue: Double,
        outputFolderMode: OutputFolderMode,
        parallelJobs: Int
    ) {
        self.inputs = inputs
        self.method = method
        self.splitValue = splitValue
        self.globalFrameRate = globalFrameRate
        self.perFileFrameRate = perFileFrameRate
        self.usePerFileFrameRate = usePerFileFrameRate
        self.codec = codec
        self.qualityMode = qualityMode
        self.qualityValue = qualityValue
        self.outputFolderMode = outputFolderMode
        self.parallelJobs = parallelJobs
    } // init

    // MARK: - Helpers

    /// Resolve the effective target frame rate for a specific input filename.
    /// Returns the per-file override when `usePerFileFrameRate` is true and a
    /// matching entry exists, otherwise returns `globalFrameRate`.
    func effectiveFrameRate(for filename: String) -> Double {
        if usePerFileFrameRate, let override = perFileFrameRate[filename] {
            return override
        }
        return globalFrameRate
    } // effectiveFrameRate
} // SplitConfig

// MARK: - Validation

extension SplitConfig {

    /// Returns a human-readable validation error, or `nil` if the config is
    /// sound. Checked by `VideoSplitter.split` before any work begins.
    var validationError: String? {
        if inputs.isEmpty {
            return "inputs must not be empty"
        }

        switch method {
        case .duration:
            if splitValue <= 0 {
                return "splitValue must be greater than 0 for duration mode"
            }
        case .segments:
            if splitValue < 1 {
                return "splitValue must be at least 1 for segments mode"
            }
        case .reencodeOnly:
            break
        }

        if qualityMode == .quality, codec != .copy {
            if qualityValue < 1 || qualityValue > 100 {
                return "qualityValue must be in [1, 100], got \(qualityValue)"
            }
        }

        if parallelJobs < 1 {
            return "parallelJobs must be at least 1, got \(parallelJobs)"
        }

        return nil
    } // validationError
} // SplitConfig extension

// MARK: - AppState -> SplitConfig Builder

extension AppState {

    /// Build a `SplitConfig` from the current AppState for the native video
    /// splitter.
    ///
    /// Mirrors `buildGifRenderConfig()`. Per-file FPS overrides are collected
    /// from each `VideoFile.customFPS` when `fpsMode == .perFile`; otherwise
    /// the map is empty and `usePerFileFrameRate` is false.
    @MainActor
    func buildSplitConfig() -> SplitConfig {
        var perFileFPS: [String: Double] = [:]
        if fpsMode == .perFile {
            for file in videoFiles {
                if let customFPS = file.customFPS {
                    perFileFPS[file.filename] = customFPS
                }
            }
        }

        return SplitConfig(
            inputs: videoFiles.map(\.url),
            method: splitMethod,
            splitValue: splitValueInSeconds,
            globalFrameRate: fpsValue,
            perFileFrameRate: perFileFPS,
            usePerFileFrameRate: fpsMode == .perFile,
            codec: outputCodec,
            qualityMode: qualityMode,
            qualityValue: qualityValue,
            outputFolderMode: outputFolderMode,
            parallelJobs: parallelJobs
        )
    } // buildSplitConfig
} // AppState extension

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SplitConfig`.
/// Call `SplitConfigTests.runAll()` from a scratch entry point under
/// `#if DEBUG` to exercise the validation logic and per-file fps lookup.
enum SplitConfigTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        let validURL = URL(fileURLWithPath: "/tmp/fake.mp4")

        // MARK: Baseline valid config

        let baseline = SplitConfig(
            inputs: [validURL],
            method: .duration,
            splitValue: 60,
            globalFrameRate: 30,
            perFileFrameRate: [:],
            usePerFileFrameRate: false,
            codec: .h264,
            qualityMode: .quality,
            qualityValue: 65,
            outputFolderMode: .perFile,
            parallelJobs: 4
        )
        check("baseline is valid", baseline.validationError == nil)

        // MARK: Empty inputs rejected

        let empty = SplitConfig(
            inputs: [], method: .duration, splitValue: 60,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("empty inputs rejected", empty.validationError != nil)

        // MARK: Duration mode with zero value rejected

        let zeroDuration = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 0,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("duration splitValue=0 rejected", zeroDuration.validationError != nil)

        // MARK: Segments mode with zero value rejected

        let zeroSegments = SplitConfig(
            inputs: [validURL], method: .segments, splitValue: 0,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("segments splitValue=0 rejected", zeroSegments.validationError != nil)

        // MARK: Reencode-only with any splitValue is fine

        let reencodeZero = SplitConfig(
            inputs: [validURL], method: .reencodeOnly, splitValue: 0,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("reencodeOnly ignores splitValue", reencodeZero.validationError == nil)

        // MARK: Quality slider bounds checked only when relevant

        let badQuality = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 60,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 500,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("quality slider 500 rejected", badQuality.validationError != nil)

        // Same slider is ignored when codec is copy
        let copyIgnoresQuality = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 60,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .copy, qualityMode: .quality, qualityValue: 500,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("copy codec ignores out-of-range quality",
              copyIgnoresQuality.validationError == nil)

        // MARK: parallelJobs >= 1 required

        let zeroJobs = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 60,
            globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 0
        )
        check("parallelJobs=0 rejected", zeroJobs.validationError != nil)

        // MARK: Per-file fps lookup

        let perFile = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 60,
            globalFrameRate: 30,
            perFileFrameRate: ["fake.mp4": 24],
            usePerFileFrameRate: true,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("per-file fps override returns override",
              perFile.effectiveFrameRate(for: "fake.mp4") == 24)
        check("per-file fps falls back to global for unknown file",
              perFile.effectiveFrameRate(for: "other.mp4") == 30)

        let singleMode = SplitConfig(
            inputs: [validURL], method: .duration, splitValue: 60,
            globalFrameRate: 30,
            perFileFrameRate: ["fake.mp4": 24],
            usePerFileFrameRate: false,
            codec: .h264, qualityMode: .quality, qualityValue: 50,
            outputFolderMode: .perFile, parallelJobs: 4
        )
        check("single mode ignores per-file map",
              singleMode.effectiveFrameRate(for: "fake.mp4") == 30)

        print("SplitConfigTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SplitConfigTests

#endif
