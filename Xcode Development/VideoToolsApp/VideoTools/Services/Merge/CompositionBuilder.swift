import Foundation
import AVFoundation
import CoreMedia
import CoreGraphics

// MARK: - CompositionBuilder

/// Assembles an `AVMutableComposition` by appending multiple source assets
/// sequentially, and (for re-encode) produces a matching
/// `AVMutableVideoComposition` that normalizes each source into a shared
/// target canvas using the user's chosen aspect mode.
///
/// This type is the native equivalent of the Python merger's `filter_complex`
/// chain: per-input scale/pad/crop to a common canvas size, followed by
/// concat.
///
/// ### Structure
///
/// The returned composition has exactly one video track and (when any source
/// has audio) one audio track. Sources are appended back-to-back starting at
/// time zero, producing a single contiguous output timeline.
///
/// Audio gaps are filled with `insertEmptyTimeRange` when a source has no
/// audio track, so the video and audio timelines stay the same total length.
///
/// ### Aspect modes
///
/// - `.letterbox`: aspect-fit the source into the target canvas, black bars
///   along the short axis. Scale = min(targetW/srcW, targetH/srcH).
/// - `.cropFill`: aspect-fill the source, cropping the long axis. Scale =
///   max(targetW/srcW, targetH/srcH).
///
/// Both modes center the source inside the canvas. Source
/// `preferredTransform` is composed first so rotated / portrait sources land
/// upright in the canvas.
///
/// ### Target canvas
///
/// Target size is `max(displayWidth)` × `max(displayHeight)` across inputs,
/// rounded up to even numbers (H.264 and HEVC both require even dimensions).
/// Matches the legacy Python behavior.
enum CompositionBuilder {

    // MARK: - Output

    /// The assembled composition plus the optional video composition for
    /// re-encode, plus the computed target canvas size for downstream
    /// consumers (writer input settings, logging, etc.).
    ///
    /// Migration note: macOS 26 deprecated `AVMutableVideoComposition` and
    /// its instruction / layer-instruction siblings in favor of the new
    /// `AVVideoComposition.Configuration` API. The deprecated classes are
    /// still fully functional and used below; a future pass should migrate
    /// to the configuration-based builders. Tracked in TODO.md.
    struct Output: @unchecked Sendable {
        /// The assembled composition. Pass to `AVAssetExportSession` (copy
        /// mode) or to `AVAssetReader` (re-encode).
        let composition: AVMutableComposition
        /// Nil in copy mode. In re-encode mode, carries the per-instruction
        /// layer transforms and target frame duration. Attach to the reader's
        /// `AVAssetReaderVideoCompositionOutput` or to an
        /// `AVAssetExportSession.videoComposition`.
        let videoComposition: AVMutableVideoComposition?
        /// Target canvas size, with even dimensions.
        let targetSize: CGSize
    } // Output

    // MARK: - Errors

    enum BuildError: Error, LocalizedError {
        case emptyInputs
        case noVideoTrack(path: String)
        case compositionTrackCreationFailed

        var errorDescription: String? {
            switch self {
            case .emptyInputs:
                return "No inputs to build composition from."
            case .noVideoTrack(let path):
                return "Source '\(path)' has no video track."
            case .compositionTrackCreationFailed:
                return "Could not create a composition track."
            }
        } // errorDescription
    } // BuildError

    // MARK: - Public API

    /// Build the composition.
    ///
    /// - Parameters:
    ///   - inputs: Source URLs in batch order.
    ///   - aspectMode: Letterbox or crop-fill. Ignored when `isReencode ==
    ///                 false` (copy mode uses the source tracks as-is).
    ///   - targetFrameRate: Output frame rate for re-encode. Applied via
    ///                      `AVMutableVideoComposition.frameDuration`.
    ///                      Ignored when `isReencode == false`.
    ///   - isReencode: When true, produces a video composition with layer
    ///                 transforms and a target frame duration. When false,
    ///                 returns `videoComposition = nil`.
    /// - Returns: Assembled composition. See `Output`.
    /// - Throws: `BuildError` on empty inputs or per-input probe failure.
    static func build(
        inputs: [URL],
        aspectMode: MergeAspectMode,
        targetFrameRate: Double,
        isReencode: Bool
    ) async throws -> Output {

        guard !inputs.isEmpty else { throw BuildError.emptyInputs }

        let composition = AVMutableComposition()
        guard let outputVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw BuildError.compositionTrackCreationFailed
        }
        // Audio output track is added lazily on first source that has audio;
        // sources that lack audio get empty time ranges inserted to preserve
        // overall duration alignment.
        var outputAudioTrack: AVMutableCompositionTrack?

        // Collect per-source metadata needed for target-size calculation and
        // per-instruction transforms. We load tracks and properties once,
        // then walk again to perform the appends.
        struct Probed {
            let asset: AVURLAsset
            let videoTrack: AVAssetTrack
            let audioTrack: AVAssetTrack?
            let naturalSize: CGSize
            let preferredTransform: CGAffineTransform
            let duration: CMTime
        }
        var probed: [Probed] = []
        probed.reserveCapacity(inputs.count)

        for url in inputs {
            let asset = AVURLAsset(url: url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            guard let videoTrack = videoTracks.first else {
                throw BuildError.noVideoTrack(path: url.path)
            }
            let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            let naturalSize = try await videoTrack.load(.naturalSize)
            let preferredTransform = try await videoTrack.load(.preferredTransform)
            let duration = try await asset.load(.duration)
            probed.append(Probed(
                asset: asset,
                videoTrack: videoTrack,
                audioTrack: audioTrack,
                naturalSize: naturalSize,
                preferredTransform: preferredTransform,
                duration: duration
            ))
        }

        // MARK: Target canvas

        // Displayed size = abs(naturalSize.applying(preferredTransform)). Take
        // absolute values since the transform may flip axes.
        func displaySize(_ p: Probed) -> CGSize {
            let applied = p.naturalSize.applying(p.preferredTransform)
            return CGSize(width: abs(applied.width), height: abs(applied.height))
        }
        let maxDisplayWidth = probed.map { displaySize($0).width }.max() ?? 0
        let maxDisplayHeight = probed.map { displaySize($0).height }.max() ?? 0
        let targetSize = CGSize(
            width: evenCeil(maxDisplayWidth),
            height: evenCeil(maxDisplayHeight)
        )

        // MARK: Append sources and build instructions

        var instructions: [AVMutableVideoCompositionInstruction] = []
        var cursor: CMTime = .zero

        for p in probed {
            let range = CMTimeRange(start: .zero, duration: p.duration)

            // Insert video at the current cursor.
            try outputVideoTrack.insertTimeRange(
                range, of: p.videoTrack, at: cursor
            )

            // Insert audio (or a silent gap of equal duration).
            if let audio = p.audioTrack {
                if outputAudioTrack == nil {
                    outputAudioTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    )
                }
                if let outAudio = outputAudioTrack {
                    try outAudio.insertTimeRange(range, of: audio, at: cursor)
                }
            } else if let outAudio = outputAudioTrack {
                // Only insert an empty range if the audio track already
                // exists; otherwise there's no audio track at all yet and
                // the silence will be handled by a future source's gap.
                outAudio.insertEmptyTimeRange(
                    CMTimeRange(start: cursor, duration: p.duration)
                )
            }

            // Build a video-composition instruction for this source's slice.
            if isReencode {
                let transform = aspectTransform(
                    source: p.naturalSize,
                    preferredTransform: p.preferredTransform,
                    target: targetSize,
                    mode: aspectMode
                )
                let layer = AVMutableVideoCompositionLayerInstruction(
                    assetTrack: outputVideoTrack
                )
                layer.setTransform(transform, at: cursor)

                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: cursor, duration: p.duration)
                instruction.layerInstructions = [layer]
                instructions.append(instruction)
            }

            cursor = CMTimeAdd(cursor, p.duration)
        }

        // MARK: Video composition (re-encode only)

        let videoComposition: AVMutableVideoComposition?
        if isReencode {
            let vc = AVMutableVideoComposition()
            vc.renderSize = targetSize
            // Target fps -> frame duration (1/fps seconds per output frame).
            // 90000 timescale is the standard HD value and gives
            // microsecond-ish PTS precision even at fractional fps.
            let fps = max(1.0, targetFrameRate)
            vc.frameDuration = CMTime(
                seconds: 1.0 / fps, preferredTimescale: 90_000
            )
            vc.instructions = instructions
            videoComposition = vc
        } else {
            videoComposition = nil
        }

        return Output(
            composition: composition,
            videoComposition: videoComposition,
            targetSize: targetSize
        )
    } // build

    // MARK: - Transform math

    /// Compute the `CGAffineTransform` that takes a source video track's
    /// natural-pixel coordinate space into the target canvas for the given
    /// aspect mode.
    ///
    /// Composition order (left to right, applied first to last on points):
    /// `preferredTransform → scale → translate`
    ///
    /// `preferredTransform` orients the source upright (rotation, flip).
    /// The resulting "displayed" rectangle may be at a non-zero origin, so
    /// the translate step also zeroes the origin before adding the
    /// centering offset.
    ///
    /// Pure function. Exposed for unit testing.
    static func aspectTransform(
        source: CGSize,
        preferredTransform: CGAffineTransform,
        target: CGSize,
        mode: MergeAspectMode
    ) -> CGAffineTransform {

        // Where does the source rect end up after preferredTransform?
        // Project all four corners and take the bounding box. This handles
        // 90/180/270 rotations plus any flips without special-casing.
        let srcRect = CGRect(origin: .zero, size: source)
        let projected = srcRect.applying(preferredTransform)
        // projected.size holds abs(dims) via CGRect conventions.
        let displaySize = projected.size

        // Scale to fit target per aspect mode.
        let scaleX = target.width / max(1.0, displaySize.width)
        let scaleY = target.height / max(1.0, displaySize.height)
        let scale: CGFloat = {
            switch mode {
            case .letterbox: return min(scaleX, scaleY)
            case .cropFill:  return max(scaleX, scaleY)
            }
        }()

        let scaledWidth = displaySize.width * scale
        let scaledHeight = displaySize.height * scale
        let offsetX = (target.width - scaledWidth) / 2.0
        let offsetY = (target.height - scaledHeight) / 2.0

        // projected.origin tells us where (0,0) landed after
        // preferredTransform. We want the scaled, centered displayed box to
        // start at (offsetX, offsetY), so we translate by:
        //   final_tx = offsetX - projected.origin.x * scale
        //   final_ty = offsetY - projected.origin.y * scale
        let tx = offsetX - projected.origin.x * scale
        let ty = offsetY - projected.origin.y * scale

        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    } // aspectTransform

    // MARK: - Helpers

    /// Round up to the nearest even integer. H.264 and HEVC both require
    /// even dimensions; the subsurface encoder errors on odd inputs.
    static func evenCeil(_ value: CGFloat) -> CGFloat {
        let rounded = ceil(value)
        return rounded.truncatingRemainder(dividingBy: 2) == 0
            ? rounded
            : rounded + 1
    } // evenCeil
} // CompositionBuilder

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `CompositionBuilder`'s pure math.
/// The actual composition assembly (which needs AVFoundation assets) is
/// covered by end-to-end smoke tests run through the UI.
enum CompositionBuilderTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        // MARK: evenCeil

        check("evenCeil 100 -> 100", CompositionBuilder.evenCeil(100) == 100)
        check("evenCeil 101 -> 102", CompositionBuilder.evenCeil(101) == 102)
        check("evenCeil 100.1 -> 102", CompositionBuilder.evenCeil(100.1) == 102)
        check("evenCeil 0 -> 0", CompositionBuilder.evenCeil(0) == 0)

        // MARK: Letterbox math — square source into widescreen target

        // Source 1000x1000, target 1920x1080, identity transform, letterbox.
        // Scale = min(1920/1000, 1080/1000) = 1.08
        // scaled = 1080x1080. Centered: offsetX = (1920-1080)/2 = 420, offsetY = 0.
        let lb = CompositionBuilder.aspectTransform(
            source: CGSize(width: 1000, height: 1000),
            preferredTransform: .identity,
            target: CGSize(width: 1920, height: 1080),
            mode: .letterbox
        )
        // Apply to the source rect and verify the resulting rect's position
        // and size.
        let lbRect = CGRect(x: 0, y: 0, width: 1000, height: 1000).applying(lb)
        check("letterbox scaled width is 1080",
              abs(lbRect.width - 1080) < 1e-6)
        check("letterbox scaled height is 1080",
              abs(lbRect.height - 1080) < 1e-6)
        check("letterbox horizontal offset is 420",
              abs(lbRect.origin.x - 420) < 1e-6)
        check("letterbox vertical offset is 0",
              abs(lbRect.origin.y - 0) < 1e-6)

        // MARK: Crop-fill math — same input

        // Scale = max(1920/1000, 1080/1000) = 1.92
        // scaled = 1920x1920. Centered: offsetX = 0, offsetY = (1080-1920)/2 = -420.
        let cf = CompositionBuilder.aspectTransform(
            source: CGSize(width: 1000, height: 1000),
            preferredTransform: .identity,
            target: CGSize(width: 1920, height: 1080),
            mode: .cropFill
        )
        let cfRect = CGRect(x: 0, y: 0, width: 1000, height: 1000).applying(cf)
        check("cropFill scaled width is 1920",
              abs(cfRect.width - 1920) < 1e-6)
        check("cropFill scaled height is 1920",
              abs(cfRect.height - 1920) < 1e-6)
        check("cropFill horizontal offset is 0",
              abs(cfRect.origin.x - 0) < 1e-6)
        check("cropFill vertical offset is -420",
              abs(cfRect.origin.y + 420) < 1e-6)

        // MARK: Portrait source into landscape target, letterbox

        // Source 1080x1920 (portrait) with a 90-degree rotation preferredTransform.
        // Applying preferredTransform: (1080, 1920) rotated -> projected is
        // 1920x1080 (landscape). So display = 1920x1080, target = 1920x1080.
        // Scale = 1.0. offset = 0,0.
        let portrait = CGAffineTransform(rotationAngle: .pi / 2)
            .translatedBy(x: 0, y: -1080)
        // After this transform, (0,0) moves to (0, 0) and (1080, 1920) moves
        // to (1920, -1080+1080=0)... let's just verify via CGRect.applying
        // that the projected bounding box is 1920 x 1080.
        let portraitRect = CGRect(x: 0, y: 0, width: 1080, height: 1920)
            .applying(portrait)
        check("portrait rotation yields landscape projection width",
              abs(portraitRect.width - 1920) < 1e-6)
        check("portrait rotation yields landscape projection height",
              abs(portraitRect.height - 1080) < 1e-6)

        let portraitLetterbox = CompositionBuilder.aspectTransform(
            source: CGSize(width: 1080, height: 1920),
            preferredTransform: portrait,
            target: CGSize(width: 1920, height: 1080),
            mode: .letterbox
        )
        let finalRect = CGRect(x: 0, y: 0, width: 1080, height: 1920)
            .applying(portraitLetterbox)
        check("portrait letterbox lands at origin 0,0",
              abs(finalRect.origin.x) < 1e-6 && abs(finalRect.origin.y) < 1e-6)
        check("portrait letterbox fills target width",
              abs(finalRect.width - 1920) < 1e-6)
        check("portrait letterbox fills target height",
              abs(finalRect.height - 1080) < 1e-6)

        print("CompositionBuilderTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // CompositionBuilderTests

#endif
