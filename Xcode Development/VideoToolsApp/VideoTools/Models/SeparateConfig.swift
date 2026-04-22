import Foundation

// MARK: - SeparateConfig

/// Configuration for a native batch video-audio separation operation.
///
/// Parallel of `SplitConfig`, `MergeConfig`, and `GifRenderConfig`. Internal
/// value type; the legacy `PythonRunner.SeparatorConfig` Codable that lived
/// alongside the Python path is replaced by this Sendable native type.
/// Consumed by `VideoSeparator`.
struct SeparateConfig: Sendable {

    // MARK: - Inputs

    /// Source video URLs, in batch order. Each input produces a
    /// `<stem>_separated/` folder with a video-only file and an audio-only
    /// WAV file.
    let inputs: [URL]

    // MARK: - Audio extraction

    /// Global target sample rate. Used when no per-file override is
    /// registered. Hz (e.g. 48_000).
    let globalSampleRate: Int

    /// Per-file sample-rate overrides keyed by filename
    /// (`URL.lastPathComponent`). When a key is present, its value takes
    /// precedence over `globalSampleRate` for that input.
    let perFileSampleRate: [String: Int]

    /// When true (`SampleRateMode.perFile`), the orchestrator looks up each
    /// input in `perFileSampleRate` and falls back to `globalSampleRate`
    /// when absent. When false, only `globalSampleRate` is used.
    let usePerFileSampleRate: Bool

    /// Output channel count. 1 = mono, 2 = stereo. Applied via the LPCM
    /// reader's `AVNumberOfChannelsKey`. CoreAudio's built-in downmixer
    /// handles source-to-target channel conversion.
    let audioChannels: Int

    // MARK: - Parallelism

    /// Maximum concurrent file separations. Each file's own
    /// video-extraction and audio-extraction sub-tasks run concurrently
    /// regardless of this value (they're within a single file's pipeline).
    /// This knob governs file-level parallelism across the batch.
    let parallelJobs: Int

    // MARK: - Init

    init(
        inputs: [URL],
        globalSampleRate: Int,
        perFileSampleRate: [String: Int],
        usePerFileSampleRate: Bool,
        audioChannels: Int,
        parallelJobs: Int
    ) {
        self.inputs = inputs
        self.globalSampleRate = globalSampleRate
        self.perFileSampleRate = perFileSampleRate
        self.usePerFileSampleRate = usePerFileSampleRate
        self.audioChannels = audioChannels
        self.parallelJobs = parallelJobs
    } // init

    // MARK: - Helpers

    /// Resolve the effective sample rate for a specific input filename.
    /// Returns the per-file override when `usePerFileSampleRate` is true
    /// and a matching entry exists, otherwise returns `globalSampleRate`.
    func effectiveSampleRate(for filename: String) -> Int {
        if usePerFileSampleRate, let override = perFileSampleRate[filename] {
            return override
        }
        return globalSampleRate
    } // effectiveSampleRate
} // SeparateConfig

// MARK: - Validation

extension SeparateConfig {

    /// Returns a human-readable validation error, or `nil` if the config
    /// is sound. Checked by `VideoSeparator.separate` before any probe
    /// work begins.
    var validationError: String? {
        if inputs.isEmpty {
            return "inputs must not be empty"
        }
        if globalSampleRate <= 0 {
            return "globalSampleRate must be greater than 0, got \(globalSampleRate)"
        }
        if audioChannels < 1 || audioChannels > 8 {
            return "audioChannels must be in [1, 8], got \(audioChannels)"
        }
        if parallelJobs < 1 {
            return "parallelJobs must be at least 1, got \(parallelJobs)"
        }
        return nil
    } // validationError
} // SeparateConfig extension

// MARK: - AppState -> SeparateConfig Builder

extension AppState {

    /// Build a `SeparateConfig` from the current AppState for the native
    /// separator.
    ///
    /// Mirrors `buildSplitConfig()`, `buildMergeConfig()`, and
    /// `buildGifRenderConfig()`. Per-file sample-rate overrides are
    /// collected from each `VideoFile.customSampleRate` when
    /// `sampleRateMode == .perFile`.
    @MainActor
    func buildSeparateConfig() -> SeparateConfig {
        var perFileRates: [String: Int] = [:]
        if sampleRateMode == .perFile {
            for file in videoFiles {
                if let customRate = file.customSampleRate {
                    perFileRates[file.filename] = customRate.rawValue
                }
            }
        }

        return SeparateConfig(
            inputs: videoFiles.map(\.url),
            globalSampleRate: sampleRate.rawValue,
            perFileSampleRate: perFileRates,
            usePerFileSampleRate: sampleRateMode == .perFile,
            audioChannels: audioChannelMode.rawValue,
            parallelJobs: parallelJobs
        )
    } // buildSeparateConfig
} // AppState extension

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SeparateConfig`.
enum SeparateConfigTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        let a = URL(fileURLWithPath: "/tmp/a.mp4")

        // MARK: Baseline valid

        let baseline = SeparateConfig(
            inputs: [a],
            globalSampleRate: 48_000,
            perFileSampleRate: [:],
            usePerFileSampleRate: false,
            audioChannels: 2,
            parallelJobs: 4
        )
        check("baseline valid", baseline.validationError == nil)

        // MARK: Empty inputs rejected

        let empty = SeparateConfig(
            inputs: [],
            globalSampleRate: 48_000,
            perFileSampleRate: [:],
            usePerFileSampleRate: false,
            audioChannels: 2,
            parallelJobs: 4
        )
        check("empty inputs rejected", empty.validationError != nil)

        // MARK: Zero sample rate rejected

        let zeroSR = SeparateConfig(
            inputs: [a], globalSampleRate: 0,
            perFileSampleRate: [:], usePerFileSampleRate: false,
            audioChannels: 2, parallelJobs: 4
        )
        check("zero sample rate rejected", zeroSR.validationError != nil)

        // MARK: Channel count out of range

        let zeroCh = SeparateConfig(
            inputs: [a], globalSampleRate: 48_000,
            perFileSampleRate: [:], usePerFileSampleRate: false,
            audioChannels: 0, parallelJobs: 4
        )
        check("audioChannels=0 rejected", zeroCh.validationError != nil)

        let manyCh = SeparateConfig(
            inputs: [a], globalSampleRate: 48_000,
            perFileSampleRate: [:], usePerFileSampleRate: false,
            audioChannels: 16, parallelJobs: 4
        )
        check("audioChannels=16 rejected", manyCh.validationError != nil)

        // MARK: parallelJobs >= 1

        let zeroJobs = SeparateConfig(
            inputs: [a], globalSampleRate: 48_000,
            perFileSampleRate: [:], usePerFileSampleRate: false,
            audioChannels: 2, parallelJobs: 0
        )
        check("parallelJobs=0 rejected", zeroJobs.validationError != nil)

        // MARK: Per-file sample rate lookup

        let perFile = SeparateConfig(
            inputs: [a], globalSampleRate: 48_000,
            perFileSampleRate: ["a.mp4": 44_100],
            usePerFileSampleRate: true,
            audioChannels: 2, parallelJobs: 4
        )
        check("per-file override returns override",
              perFile.effectiveSampleRate(for: "a.mp4") == 44_100)
        check("per-file falls back to global for unknown file",
              perFile.effectiveSampleRate(for: "other.mp4") == 48_000)

        let singleMode = SeparateConfig(
            inputs: [a], globalSampleRate: 48_000,
            perFileSampleRate: ["a.mp4": 44_100],
            usePerFileSampleRate: false,
            audioChannels: 2, parallelJobs: 4
        )
        check("single mode ignores per-file map",
              singleMode.effectiveSampleRate(for: "a.mp4") == 48_000)

        print("SeparateConfigTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SeparateConfigTests

#endif
