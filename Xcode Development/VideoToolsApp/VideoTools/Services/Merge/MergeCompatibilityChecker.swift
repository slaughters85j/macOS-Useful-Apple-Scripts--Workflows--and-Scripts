import Foundation
import CoreMedia

// MARK: - InputVideoInfo

/// Per-input metadata snapshot used by the compatibility checker and the
/// orchestrator. Populated via AVFoundation at probe time.
///
/// Values are already normalized to the displayed orientation (i.e.
/// `displayWidth`/`displayHeight` reflect `preferredTransform` applied), so
/// downstream consumers don't have to re-reason about rotation.
struct InputVideoInfo: Sendable, Equatable {
    /// Source file URL. Used for error messages.
    let url: URL
    /// Four-character code for the video track's format description. Used to
    /// verify codec-identity for copy mode. Zero means "unknown" and forces
    /// a copy-mode failure.
    let codecFourCC: UInt32
    /// Displayed width in pixels (post preferredTransform).
    let displayWidth: Int
    /// Displayed height in pixels (post preferredTransform).
    let displayHeight: Int
    /// Track's nominal frame rate. Zero when AVFoundation can't provide one
    /// (rare on real-world files).
    let nominalFrameRate: Double
    /// Duration in seconds. Not used by compatibility checking itself, but
    /// carried on the same struct to avoid a parallel metadata array.
    let duration: Double
    /// True when the source has at least one audio track. Used by
    /// `CompositionBuilder` to insert silence for audio-less inputs.
    let hasAudio: Bool
    /// Source video track's estimated data rate in bits per second. Used as
    /// the H.264 bitrate anchor for quality-slider mapping when merging
    /// heterogeneous inputs. Zero when unavailable.
    let estimatedDataRate: Int

    init(
        url: URL,
        codecFourCC: UInt32,
        displayWidth: Int,
        displayHeight: Int,
        nominalFrameRate: Double,
        duration: Double,
        hasAudio: Bool,
        estimatedDataRate: Int
    ) {
        self.url = url
        self.codecFourCC = codecFourCC
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        self.nominalFrameRate = nominalFrameRate
        self.duration = duration
        self.hasAudio = hasAudio
        self.estimatedDataRate = estimatedDataRate
    } // init
} // InputVideoInfo

// MARK: - MergeCompatibilityChecker

/// Pure compatibility check for copy-mode merging.
///
/// ffmpeg's concat demuxer (used by the legacy Python merger in copy mode)
/// only works when all inputs share codec, dimensions, and frame rate. The
/// AVFoundation equivalent (`AVMutableComposition` + `AVAssetExportPresetPassthrough`)
/// imposes the same restriction in practice — mismatches cause silent video
/// corruption, player rejections, or outright export failures depending on
/// the mismatch.
///
/// This checker produces a human-readable error string the orchestrator
/// surfaces as a `fileError` event, or `nil` when the inputs are safe for
/// copy-mode merging.
///
/// Tolerances match the legacy script:
/// - Dimensions within 2 pixels (absorbs off-by-one rounding on odd-pixel
///   sources that various encoders handle differently).
/// - Frame rate within 0.5 fps (absorbs NTSC-fractional noise like 29.97 vs
///   29.970029...).
/// - Codec FourCC must match exactly.
enum MergeCompatibilityChecker {

    // MARK: - Public API

    /// Returns `nil` when the inputs are safe to merge in copy mode, or a
    /// human-readable error string describing the first mismatch otherwise.
    ///
    /// - Parameter inputs: Probed video info for each input, in batch order.
    ///                     Must be non-empty; an empty array returns an
    ///                     error string (callers should already be blocking
    ///                     the Process button below 2 inputs, but we guard
    ///                     explicitly anyway).
    static func copyModeError(inputs: [InputVideoInfo]) -> String? {
        guard !inputs.isEmpty else {
            return "No inputs to merge."
        }
        guard inputs.count >= 2 else {
            // Technically a one-input "merge" works, but the UI shouldn't
            // allow it and matching Python's behavior is cleaner.
            return "Merging requires at least two input videos."
        }

        let first = inputs[0]

        for candidate in inputs.dropFirst() {
            if candidate.codecFourCC == 0 || first.codecFourCC == 0 {
                return "Could not determine video codec for one or more inputs. Switch to H.264 or HEVC to merge."
            }
            if candidate.codecFourCC != first.codecFourCC {
                return "Copy codec requires all inputs to share the same video codec. '\(first.url.lastPathComponent)' and '\(candidate.url.lastPathComponent)' differ. Switch to H.264 or HEVC to merge."
            }
            if abs(candidate.displayWidth - first.displayWidth) > 2 ||
               abs(candidate.displayHeight - first.displayHeight) > 2 {
                return "Copy codec requires all inputs to share the same resolution. '\(first.url.lastPathComponent)' is \(first.displayWidth)x\(first.displayHeight) but '\(candidate.url.lastPathComponent)' is \(candidate.displayWidth)x\(candidate.displayHeight). Switch to H.264 or HEVC to merge."
            }
            if abs(candidate.nominalFrameRate - first.nominalFrameRate) > 0.5 {
                return "Copy codec requires all inputs to share the same frame rate. '\(first.url.lastPathComponent)' is \(fpsString(first.nominalFrameRate)) fps but '\(candidate.url.lastPathComponent)' is \(fpsString(candidate.nominalFrameRate)) fps. Switch to H.264 or HEVC to merge."
            }
        }

        return nil
    } // copyModeError

    // MARK: - Helpers

    /// Format an fps value for the error message. Trims trailing zeros so
    /// "30" reads cleaner than "30.0".
    private static func fpsString(_ fps: Double) -> String {
        if fps == fps.rounded() {
            return String(format: "%.0f", fps)
        }
        return String(format: "%.2f", fps)
    } // fpsString
} // MergeCompatibilityChecker

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `MergeCompatibilityChecker`.
enum MergeCompatibilityCheckerTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        // Helpers. All fields explicit to make drift obvious if InputVideoInfo
        // grows new ones.
        func info(
            name: String,
            fourCC: UInt32 = fourCC("avc1"),
            w: Int = 1920,
            h: Int = 1080,
            fps: Double = 30,
            audio: Bool = true
        ) -> InputVideoInfo {
            InputVideoInfo(
                url: URL(fileURLWithPath: "/tmp/\(name)"),
                codecFourCC: fourCC,
                displayWidth: w,
                displayHeight: h,
                nominalFrameRate: fps,
                duration: 10,
                hasAudio: audio,
                estimatedDataRate: 5_000_000
            )
        } // info

        // MARK: Empty / single-input rejection

        check("empty inputs rejected",
              MergeCompatibilityChecker.copyModeError(inputs: []) != nil)
        check("single input rejected",
              MergeCompatibilityChecker.copyModeError(inputs: [info(name: "a.mp4")]) != nil)

        // MARK: Matching inputs pass

        let matched = [
            info(name: "a.mp4"),
            info(name: "b.mp4"),
            info(name: "c.mp4")
        ]
        check("three matching inputs pass",
              MergeCompatibilityChecker.copyModeError(inputs: matched) == nil)

        // MARK: Codec mismatch

        let codecMismatch = [
            info(name: "a.mp4", fourCC: fourCC("avc1")),
            info(name: "b.mp4", fourCC: fourCC("hvc1"))
        ]
        check("codec mismatch rejected",
              MergeCompatibilityChecker.copyModeError(inputs: codecMismatch) != nil)

        // MARK: Unknown codec rejected

        let unknownCodec = [
            info(name: "a.mp4", fourCC: 0),
            info(name: "b.mp4", fourCC: fourCC("avc1"))
        ]
        check("unknown codec rejected",
              MergeCompatibilityChecker.copyModeError(inputs: unknownCodec) != nil)

        // MARK: Dimensions within 2 px pass

        let tinyDiff = [
            info(name: "a.mp4", w: 1920, h: 1080),
            info(name: "b.mp4", w: 1919, h: 1081)
        ]
        check("dimensions within 2 px tolerated",
              MergeCompatibilityChecker.copyModeError(inputs: tinyDiff) == nil)

        let bigDiff = [
            info(name: "a.mp4", w: 1920, h: 1080),
            info(name: "b.mp4", w: 1280, h: 720)
        ]
        check("dimensions outside tolerance rejected",
              MergeCompatibilityChecker.copyModeError(inputs: bigDiff) != nil)

        // MARK: fps within 0.5 pass, outside fail

        let fpsClose = [
            info(name: "a.mp4", fps: 30),
            info(name: "b.mp4", fps: 29.97)
        ]
        check("fps within 0.5 tolerated",
              MergeCompatibilityChecker.copyModeError(inputs: fpsClose) == nil)

        let fpsFar = [
            info(name: "a.mp4", fps: 30),
            info(name: "b.mp4", fps: 24)
        ]
        check("fps outside tolerance rejected",
              MergeCompatibilityChecker.copyModeError(inputs: fpsFar) != nil)

        print("MergeCompatibilityCheckerTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll

    /// Build a FourCC value from a 4-character ASCII string. Helper for tests.
    private static func fourCC(_ s: String) -> UInt32 {
        precondition(s.count == 4)
        var result: UInt32 = 0
        for byte in s.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    } // fourCC
} // MergeCompatibilityCheckerTests

#endif
