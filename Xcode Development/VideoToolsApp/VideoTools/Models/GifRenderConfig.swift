import Foundation

// MARK: - GifRenderConfig

/// Configuration for a native batch GIF/APNG render operation.
///
/// Unlike the merger JSON config used by the Python script, this type is
/// internal, never leaves the process, and has no Codable conformance. It is
/// consumed by `GifRenderer` and its supporting services.
struct GifRenderConfig: Sendable {

    // MARK: - Inputs

    /// Video file URLs to process in batch order.
    let inputs: [URL]

    // MARK: - Output

    /// Output format (`.gif` or `.apng`).
    let outputFormat: GifOutputFormat

    /// Resolution directive (original, scale percent, fixed width, or explicit W x H).
    let resolution: ResolutionSpec

    // MARK: - Timing

    /// Output frame rate in frames per second.
    let frameRate: Double

    /// Playback speed multiplier. 1.0 is real time, 2.0 is double speed, 0.5 is half speed.
    let speedMultiplier: Double

    /// GIF/APNG loop count. 0 means infinite, 1 means play once, N means play N times.
    /// The caller converts `GifLoopMode` plus any custom count to this absolute integer.
    let loopCount: Int

    // MARK: - Trim and Cuts

    /// Start time in the source timeline to begin output from.
    let trimStart: Double

    /// End time in the source timeline to stop output at. `nil` means use source duration.
    let trimEnd: Double?

    /// Segments to REMOVE from the kept range. Each cut is expressed in the source timeline.
    let cutSegments: [CutSegment]

    // MARK: - Overlay

    /// Optional text overlay. `nil` disables overlay rendering.
    ///
    /// The overlay's startTime/endTime live in the SOURCE timeline. The renderer is
    /// responsible for remapping them to the OUTPUT timeline after trim and cuts
    /// have been applied.
    let textOverlay: TextOverlay?

    // MARK: - Init

    init(
        inputs: [URL],
        outputFormat: GifOutputFormat,
        resolution: ResolutionSpec,
        frameRate: Double,
        speedMultiplier: Double,
        loopCount: Int,
        trimStart: Double,
        trimEnd: Double?,
        cutSegments: [CutSegment],
        textOverlay: TextOverlay?
    ) {
        self.inputs = inputs
        self.outputFormat = outputFormat
        self.resolution = resolution
        self.frameRate = frameRate
        self.speedMultiplier = speedMultiplier
        self.loopCount = loopCount
        self.trimStart = trimStart
        self.trimEnd = trimEnd
        self.cutSegments = cutSegments
        self.textOverlay = textOverlay
    } // init
} // GifRenderConfig

// MARK: - ResolutionSpec

/// Strongly-typed resolution directive carrying its parameters inline.
///
/// This is the renderer-facing projection of `GifResolutionMode` plus the relevant
/// AppState sliders/fields. It exists so downstream code does not have to carry
/// around four loosely-related values that are only meaningful in one combination.
///
/// Code Reuse Candidate: if Split or Separate A/V ever gain output-resolution control,
/// this enum should move to a shared location and be reused instead of re-implemented.
enum ResolutionSpec: Sendable, Equatable {

    /// Keep source dimensions unchanged.
    case original

    /// Uniform scale factor in the open-closed interval (0, 1].
    /// 0.5 means half of each source dimension.
    case scalePercent(Double)

    /// Fixed output width in pixels. Height is computed by the renderer to preserve aspect ratio.
    case fixedWidth(Int)

    /// Explicit output width and height in pixels.
    case custom(width: Int, height: Int)
} // ResolutionSpec

// MARK: - Validation

extension ResolutionSpec {

    /// Returns a human-readable validation error string, or `nil` if the spec is sound.
    var validationError: String? {
        switch self {
        case .original:
            return nil
        case .scalePercent(let p):
            if p <= 0 || p > 1.0 {
                return "scalePercent must be in (0, 1], got \(p)"
            }
            return nil
        case .fixedWidth(let w):
            if w <= 0 {
                return "fixedWidth must be greater than 0, got \(w)"
            }
            return nil
        case .custom(let w, let h):
            if w <= 0 {
                return "custom width must be greater than 0, got \(w)"
            }
            if h <= 0 {
                return "custom height must be greater than 0, got \(h)"
            }
            return nil
        }
    } // validationError
} // ResolutionSpec

extension GifRenderConfig {

    /// Returns a human-readable validation error string, or `nil` if the config is sound.
    ///
    /// The renderer should call this as its first step and short-circuit with an error
    /// event if non-nil. This gives a single centralized check rather than scattering
    /// precondition failures across the pipeline.
    var validationError: String? {
        if inputs.isEmpty {
            return "inputs must not be empty"
        }
        if let e = resolution.validationError {
            return e
        }
        if frameRate <= 0 || frameRate > 120 {
            return "frameRate must be in (0, 120], got \(frameRate)"
        }
        if speedMultiplier <= 0 {
            return "speedMultiplier must be greater than 0, got \(speedMultiplier)"
        }
        if loopCount < 0 {
            return "loopCount must be at least 0 (0 = infinite), got \(loopCount)"
        }
        if trimStart < 0 {
            return "trimStart must be at least 0, got \(trimStart)"
        }
        if let end = trimEnd, end <= trimStart {
            return "trimEnd (\(end)) must be greater than trimStart (\(trimStart))"
        }
        return nil
    } // validationError
} // GifRenderConfig

// MARK: - AppState -> GifRenderConfig Builder

extension AppState {

    /// Build a `GifRenderConfig` from the current AppState for the native GIF
    /// render pipeline.
    ///
    /// - Input mapping: `gifScalePercent` is stored on AppState as 10...100 and
    ///   converted to the 0...1 range that `ResolutionSpec.scalePercent` expects.
    @MainActor
    func buildGifRenderConfig() -> GifRenderConfig {
        let loopValue: Int = switch gifLoopMode {
        case .infinite: 0
        case .once:     1
        case .custom:   gifLoopCount
        }

        let resolution: ResolutionSpec = switch gifResolutionMode {
        case .original: .original
        case .scale:    .scalePercent(gifScalePercent / 100.0)
        case .width:    .fixedWidth(gifFixedWidth)
        case .custom:   .custom(width: gifCustomWidth, height: gifCustomHeight)
        }

        return GifRenderConfig(
            inputs: videoFiles.map(\.url),
            outputFormat: gifOutputFormat,
            resolution: resolution,
            frameRate: gifFrameRate,
            speedMultiplier: gifSpeedMultiplier,
            loopCount: loopValue,
            trimStart: gifTrimStart,
            trimEnd: gifTrimEnd,
            cutSegments: gifCutSegments,
            textOverlay: gifTextOverlay
        )
    } // buildGifRenderConfig
} // AppState extension

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `GifRenderConfig` and `ResolutionSpec`.
/// Call `GifRenderConfigTests.runAll()` from a scratch entry point, the app delegate,
/// or (when a test target is added) a real XCTest case.
enum GifRenderConfigTests {

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

        // ResolutionSpec validation
        check("original is valid",
              ResolutionSpec.original.validationError == nil)
        check("scale 0.5 is valid",
              ResolutionSpec.scalePercent(0.5).validationError == nil)
        check("scale 1.0 is valid",
              ResolutionSpec.scalePercent(1.0).validationError == nil)
        check("scale 0 is invalid",
              ResolutionSpec.scalePercent(0).validationError != nil)

        check("scale 1.5 is invalid",
              ResolutionSpec.scalePercent(1.5).validationError != nil)
        check("fixedWidth 480 is valid",
              ResolutionSpec.fixedWidth(480).validationError == nil)
        check("fixedWidth 0 is invalid",
              ResolutionSpec.fixedWidth(0).validationError != nil)
        check("custom 640x480 is valid",
              ResolutionSpec.custom(width: 640, height: 480).validationError == nil)
        check("custom 0x480 is invalid",
              ResolutionSpec.custom(width: 0, height: 480).validationError != nil)
        check("custom 640x-1 is invalid",
              ResolutionSpec.custom(width: 640, height: -1).validationError != nil)

        // Config validation
        let validURL = URL(fileURLWithPath: "/tmp/fake.mp4")

        let baseline = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .scalePercent(0.5),
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("baseline GIF config valid",
              baseline.validationError == nil)

        let apngBaseline = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .apng,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("baseline APNG config valid",
              apngBaseline.validationError == nil)

        let emptyInputs = GifRenderConfig(
            inputs: [],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("empty inputs rejected",
              emptyInputs.validationError != nil)

        let badTrim = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 5.0,
            trimEnd: 5.0,
            cutSegments: [],
            textOverlay: nil
        )
        check("trimEnd equal to trimStart rejected",
              badTrim.validationError != nil)

        let badFps = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 0,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("frameRate 0 rejected",
              badFps.validationError != nil)

        let negativeLoop = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: -1,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("loopCount -1 rejected",
              negativeLoop.validationError != nil)

        let infiniteLoop = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1.0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("loopCount 0 (infinite) accepted",
              infiniteLoop.validationError == nil)

        let zeroSpeed = GifRenderConfig(
            inputs: [validURL],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 0,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        check("speedMultiplier 0 rejected",
              zeroSpeed.validationError != nil)

        print("GifRenderConfigTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // GifRenderConfigTests

#endif
