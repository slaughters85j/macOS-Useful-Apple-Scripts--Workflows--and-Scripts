import Foundation
import Foundation
import AVFoundation
import CoreGraphics
import CoreMedia

// MARK: - VideoFrameExtractor

/// Native frame extraction for GIF rendering using AVFoundation.
///
/// Given a source video URL, a set of kept ranges (in source timeline), an
/// output frame rate, a speed multiplier, and target output dimensions, this
/// actor yields decoded `CGImage` frames in OUTPUT timeline order via a
/// caller-supplied async callback.
///
/// This replaces the legacy Python pipeline's two-stage dance of:
///   1. ffmpeg re-encoding each kept segment to an intermediate MP4 via libx264
///   2. ffmpeg concatenating segments and applying fps/scale filters to produce frames
///
/// The native path skips intermediate encoding entirely. `AVAssetImageGenerator`
/// decodes frames directly at requested source times, and the cut/trim/speed math
/// is done in pure Swift via `KeepSegmentCalculator` outputs.
///
/// ### Thread safety
/// Actor isolation serializes calls. Within a single `extractFrames` invocation,
/// frame generation is serial by design (the legacy pipeline's parallelism was
/// in libx264 encode, which doesn't exist in the native GIF/APNG path). Callers
/// can invoke from multiple tasks, but per-file extraction is single-threaded.
actor VideoFrameExtractor {

    // MARK: - Types

    /// A frame extracted from the source video with timing metadata.
    ///
    /// `@unchecked Sendable` because `CGImage` is immutable after creation and
    /// safe to pass across isolation boundaries. Apple has not yet marked
    /// `CGImage` Sendable in the standard library.
    struct ExtractedFrame: @unchecked Sendable {
        let image: CGImage
        let index: Int
        let outputTime: Double
        let sourceTime: Double
    } // ExtractedFrame

    // MARK: - Errors

    /// Errors surfaced by probe and extraction operations.
    enum ExtractError: Error, LocalizedError {
        case sourceLoadFailed(URL, underlying: Error)
        case noVideoTrack(URL)
        case emptyKeepRanges
        case unsupportedDuration(URL)
        case invalidFrameRate(Double)
        case invalidSpeedMultiplier(Double)
        case invalidTargetDimensions(width: Int, height: Int)
        case frameGenerationFailed(sourceTime: Double, underlying: Error?)

        var errorDescription: String? {
            switch self {
            case .sourceLoadFailed(let url, let err):
                return "Failed to load video at \(url.path): \(err.localizedDescription)"
            case .noVideoTrack(let url):
                return "No video track found in \(url.path)"
            case .emptyKeepRanges:
                return "Trim and cut configuration produces no frames (empty keep ranges)"
            case .unsupportedDuration(let url):
                return "Could not determine duration for \(url.path)"
            case .invalidFrameRate(let fps):
                return "Invalid frame rate: \(fps) (must be > 0)"
            case .invalidSpeedMultiplier(let s):
                return "Invalid speed multiplier: \(s) (must be > 0)"
            case .invalidTargetDimensions(let w, let h):
                return "Invalid target dimensions: \(w) x \(h) (must both be >= 2)"
            case .frameGenerationFailed(let t, let err):
                let tail = err.map { ": \($0.localizedDescription)" } ?? ""
                return "Frame generation failed at source time \(t)\(tail)"
            }
        } // errorDescription
    } // ExtractError

    // MARK: - Probe

    /// Load source duration and natural video dimensions using AVFoundation.
    ///
    /// This replaces the `ffprobe` subprocess dependency for the GIF path.
    /// Dimensions are the TRACK's natural size (pre-transform). Orientation
    /// is handled at extraction time via `appliesPreferredTrackTransform`.
    ///
    /// - Parameter url: Source video file URL.
    /// - Returns: Tuple of (duration in seconds, width in pixels, height in pixels).
    /// - Throws: `ExtractError.sourceLoadFailed`, `.noVideoTrack`, or `.unsupportedDuration`.
    func probe(url: URL) async throws -> (duration: Double, width: Int, height: Int) {
        let asset = AVURLAsset(url: url)

        // Load duration and tracks concurrently.
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        do {
            async let durationLoad = asset.load(.duration)
            async let tracksLoad = asset.loadTracks(withMediaType: .video)
            duration = try await durationLoad
            videoTracks = try await tracksLoad
        } catch {
            throw ExtractError.sourceLoadFailed(url, underlying: error)
        }

        guard let videoTrack = videoTracks.first else {
            throw ExtractError.noVideoTrack(url)
        }

        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else {
            throw ExtractError.unsupportedDuration(url)
        }

        let naturalSize: CGSize
        do {
            naturalSize = try await videoTrack.load(.naturalSize)
        } catch {
            throw ExtractError.sourceLoadFailed(url, underlying: error)
        }

        // Clamp to sane integers. AVFoundation may return fractional natural sizes
        // for some exotic tracks; we round to nearest and enforce minimum 2.
        let width = max(2, Int(naturalSize.width.rounded()))
        let height = max(2, Int(naturalSize.height.rounded()))
        return (duration: seconds, width: width, height: height)
    } // probe

    // MARK: - Frame Timing

    /// Metadata for one output frame prior to decoding.
    struct FrameSchedule: Equatable, Sendable {
        let index: Int
        let outputTime: Double
        let sourceTime: Double
    } // FrameSchedule

    /// Compute the source-timeline sample time for each output frame.
    ///
    /// Walks `keepRanges` and an output cursor in lockstep (O(frames + ranges)).
    /// Called by `extractFrames`; exposed internally so validation tests can
    /// exercise the math without running AVFoundation.
    ///
    /// For each output frame index `i` at output time `tOut = i / frameRate`:
    ///   1. Find the keep range whose output-timeline slice contains `tOut`.
    ///   2. Compute `sourceTime = range.start + (tOut - outputCursor) * speedMultiplier`.
    ///
    /// Frame count comes from `outputDuration * frameRate` rounded to nearest,
    /// which is exact when trim bounds are frame-snapped (they always are,
    /// per `KeepSegmentCalculator`).
    static func computeFrameSchedule(
        keepRanges: [TimeRange],
        frameRate: Double,
        speedMultiplier: Double
    ) -> [FrameSchedule] {
        guard !keepRanges.isEmpty, frameRate > 0, speedMultiplier > 0 else {
            return []
        }
        let totalKeep = keepRanges.reduce(0.0) { $0 + $1.duration }
        let outputDuration = totalKeep / speedMultiplier
        let frameCount = Int((outputDuration * frameRate).rounded())
        guard frameCount > 0 else { return [] }

        var schedule: [FrameSchedule] = []
        schedule.reserveCapacity(frameCount)

        var cursor = 0.0
        var frameIndex = 0

        for range in keepRanges {
            let rangeOutputDuration = range.duration / speedMultiplier
            let nextCursor = cursor + rangeOutputDuration

            while frameIndex < frameCount {
                let tOut = Double(frameIndex) / frameRate
                if tOut >= nextCursor { break }
                let offsetOutput = tOut - cursor
                let offsetSource = offsetOutput * speedMultiplier
                let sourceTime = range.start + offsetSource
                schedule.append(FrameSchedule(
                    index: frameIndex,
                    outputTime: tOut,
                    sourceTime: sourceTime
                ))
                frameIndex += 1
            }

            cursor = nextCursor
            if frameIndex >= frameCount { break }
        }
        return schedule
    } // computeFrameSchedule

    // MARK: - Extraction

    /// Extract frames from a video and deliver them to `onFrame` in output order.
    ///
    /// The caller's `onFrame` closure is invoked once per successfully decoded
    /// frame, in ascending `index` order. If a specific frame fails to decode,
    /// it is SKIPPED (not yielded) and a diagnostic is logged. If extraction
    /// setup fails, this function throws before any frames are emitted.
    ///
    /// Order guarantee: even though `AVAssetImageGenerator.images(for:)` may
    /// yield results in any order, this method reorders them internally via a
    /// sliding-window buffer and calls `onFrame` in strict output-index order.
    ///
    /// The decoded `CGImage` is bounded to a square of `max(targetWidth, targetHeight)`
    /// pixels to cap memory usage. The GifRenderer compose step is expected to
    /// draw it into the final target-sized canvas, which may involve an extra
    /// scale pass for custom aspect ratios.
    ///
    /// - Parameters:
    ///   - url: Source video file URL.
    ///   - keepRanges: Source-timeline ranges to sample from, in order.
    ///   - frameRate: Output frames per second (> 0).
    ///   - speedMultiplier: Playback speed (> 0; 1.0 = real time, 2.0 = 2x).
    ///   - targetWidth: Final output canvas width in pixels (>= 2).
    ///   - targetHeight: Final output canvas height in pixels (>= 2).
    ///   - onFrame: Async throwing callback invoked once per decoded frame.
    /// - Throws: `ExtractError` for setup failures; rethrows any error from `onFrame`.
    func extractFrames(
        url: URL,
        keepRanges: [TimeRange],
        frameRate: Double,
        speedMultiplier: Double,
        targetWidth: Int,
        targetHeight: Int,
        onFrame: @Sendable (ExtractedFrame) async throws -> Void
    ) async throws {
        // MARK: Validate inputs
        guard frameRate > 0 else { throw ExtractError.invalidFrameRate(frameRate) }
        guard speedMultiplier > 0 else { throw ExtractError.invalidSpeedMultiplier(speedMultiplier) }
        guard targetWidth >= 2, targetHeight >= 2 else {
            throw ExtractError.invalidTargetDimensions(width: targetWidth, height: targetHeight)
        }
        guard !keepRanges.isEmpty else { throw ExtractError.emptyKeepRanges }

        // MARK: Build schedule
        let schedule = Self.computeFrameSchedule(
            keepRanges: keepRanges,
            frameRate: frameRate,
            speedMultiplier: speedMultiplier
        )
        guard !schedule.isEmpty else { return }

        // MARK: Load asset
        let asset = AVURLAsset(url: url)
        do {
            _ = try await asset.load(.duration)
            _ = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw ExtractError.sourceLoadFailed(url, underlying: error)
        }

        // MARK: Configure generator
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let maxDim = max(targetWidth, targetHeight)
        generator.maximumSize = CGSize(width: maxDim, height: maxDim)

        // MARK: Build CMTime array and lookup
        // Use preferredTimescale 90000 (standard HD timescale, ~11us precision)
        // to avoid CMTime.value collisions for slow-mo at high fps. Track schedule
        // entries by CMTime.value so we can match results back.
        let timescale: CMTimeScale = 90_000
        var cmTimes: [CMTime] = []
        cmTimes.reserveCapacity(schedule.count)
        var scheduleByTimeValue: [Int64: FrameSchedule] = [:]
        scheduleByTimeValue.reserveCapacity(schedule.count)
        for entry in schedule {
            let cm = CMTime(seconds: entry.sourceTime, preferredTimescale: timescale)
            cmTimes.append(cm)
            scheduleByTimeValue[cm.value] = entry
        }

        // MARK: Decode and emit
        // Sliding-window reorder: results may come in any order; buffer
        // out-of-order frames and drain the head of the queue whenever
        // contiguous frames become available. Failed indices are tracked
        // explicitly so the drain head can skip past them in real-time
        // (avoids buffering all subsequent frames when one fails early).
        var pending: [Int: ExtractedFrame] = [:]
        var failedIndices: Set<Int> = []
        var nextIndex = 0

        for await result in generator.images(for: cmTimes) {
            let requested = result.requestedTime
            let matchedEntry = scheduleByTimeValue[requested.value]

            let image: CGImage
            let actual: CMTime
            do {
                image = try result.image
                actual = try result.actualTime
            } catch {
                let srcSeconds = requested.seconds
                NSLog(
                    "[VideoFrameExtractor] Frame decode failed at source time %.4fs: %@",
                    srcSeconds,
                    error.localizedDescription
                )
                if let entry = matchedEntry {
                    failedIndices.insert(entry.index)
                    try await drainHead(
                        pending: &pending,
                        failedIndices: &failedIndices,
                        nextIndex: &nextIndex,
                        onFrame: onFrame
                    )
                }
                continue
            }

            guard let entry = matchedEntry else {
                NSLog(
                    "[VideoFrameExtractor] Unmatched result at requested time %lld",
                    requested.value
                )
                continue
            }

            let frame = ExtractedFrame(
                image: image,
                index: entry.index,
                outputTime: entry.outputTime,
                sourceTime: actual.seconds.isFinite ? actual.seconds : entry.sourceTime
            )
            pending[entry.index] = frame

            try await drainHead(
                pending: &pending,
                failedIndices: &failedIndices,
                nextIndex: &nextIndex,
                onFrame: onFrame
            )
        }

        // MARK: Flush remainder
        // If the generator silently dropped any results (no failure callback,
        // no success callback), their indices are neither in pending nor in
        // failedIndices. Treat any leftover gap as a silent drop and emit
        // whatever remains in ascending order so the caller sees a contiguous
        // prefix of whatever actually decoded.
        let remaining = pending.keys.sorted()
        for idx in remaining {
            if let frame = pending.removeValue(forKey: idx) {
                try await onFrame(frame)
            }
        }
    } // extractFrames

    // MARK: - Drain Helper

    /// Advance `nextIndex` past any contiguous run of ready frames or known
    /// failures, invoking `onFrame` for each ready frame in order.
    private func drainHead(
        pending: inout [Int: ExtractedFrame],
        failedIndices: inout Set<Int>,
        nextIndex: inout Int,
        onFrame: @Sendable (ExtractedFrame) async throws -> Void
    ) async throws {
        while true {
            if failedIndices.remove(nextIndex) != nil {
                nextIndex += 1
                continue
            }
            guard let ready = pending.removeValue(forKey: nextIndex) else { break }
            try await onFrame(ready)
            nextIndex += 1
        }
    } // drainHead

} // VideoFrameExtractor actor


// MARK: - Validation Tests

#if DEBUG

/// Validation tests for VideoFrameExtractor. Tests focus on pure Swift logic
/// (scheduling, error surfaces, input validation) that can be exercised
/// without a real video asset. Full AVFoundation integration is verified by
/// end-to-end runs against known-good outputs.
enum VideoFrameExtractorTests {

    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        var passed = 0
        var failures: [String] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            if pass { passed += 1 }
            else { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }

        // MARK: Schedule math

        // 1. Single range, speed 1, integer frame count
        let s1 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [TimeRange(start: 5.0, end: 15.0)],
            frameRate: 10.0, speedMultiplier: 1.0
        )
        check("single range speed 1 count", s1.count == 100, "got \(s1.count)")
        check("single range speed 1 first",
              s1.first?.sourceTime == 5.0 && s1.first?.outputTime == 0.0)
        check("single range speed 1 last",
              abs((s1.last?.sourceTime ?? 0) - 14.9) < 1e-9,
              "got \(s1.last?.sourceTime ?? -1)")

        // 2. Single range, speed 2 (2x faster)
        let s2 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [TimeRange(start: 0.0, end: 10.0)],
            frameRate: 10.0, speedMultiplier: 2.0
        )
        check("speed 2 count halved", s2.count == 50, "got \(s2.count)")
        check("speed 2 source jumps 0.2s",
              abs((s2[1].sourceTime) - 0.2) < 1e-9,
              "got \(s2[1].sourceTime)")

        // 3. Single range, speed 0.5 (slow-mo)
        let s3 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [TimeRange(start: 0.0, end: 4.0)],
            frameRate: 10.0, speedMultiplier: 0.5
        )
        check("speed 0.5 count doubled", s3.count == 80, "got \(s3.count)")
        check("speed 0.5 source step 0.05s",
              abs(s3[1].sourceTime - 0.05) < 1e-9,
              "got \(s3[1].sourceTime)")

        // 4. Multiple ranges concatenated
        let s4 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [
                TimeRange(start: 0.0, end: 2.0),
                TimeRange(start: 10.0, end: 13.0)
            ],
            frameRate: 10.0, speedMultiplier: 1.0
        )
        check("multi range count", s4.count == 50, "got \(s4.count)")
        check("multi range first range last source",
              abs(s4[19].sourceTime - 1.9) < 1e-9,
              "got s4[19]=\(s4[19].sourceTime)")
        check("multi range second range first source",
              abs(s4[20].sourceTime - 10.0) < 1e-9,
              "got s4[20]=\(s4[20].sourceTime)")

        // 5. Empty ranges -> empty schedule
        check("empty ranges",
              VideoFrameExtractor.computeFrameSchedule(
                keepRanges: [], frameRate: 10, speedMultiplier: 1).isEmpty)

        // 6. Zero/negative fps -> empty
        check("zero fps",
              VideoFrameExtractor.computeFrameSchedule(
                keepRanges: [TimeRange(start: 0, end: 1)], frameRate: 0, speedMultiplier: 1
              ).isEmpty)
        check("negative fps",
              VideoFrameExtractor.computeFrameSchedule(
                keepRanges: [TimeRange(start: 0, end: 1)], frameRate: -5, speedMultiplier: 1
              ).isEmpty)

        // 7. Zero/negative speed -> empty
        check("zero speed",
              VideoFrameExtractor.computeFrameSchedule(
                keepRanges: [TimeRange(start: 0, end: 1)], frameRate: 10, speedMultiplier: 0
              ).isEmpty)

        // 8. Indices are sequential from 0
        let s8 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [
                TimeRange(start: 0.0, end: 1.0),
                TimeRange(start: 5.0, end: 6.0)
            ],
            frameRate: 10.0, speedMultiplier: 1.0
        )
        var allSequential = true
        for (i, entry) in s8.enumerated() where entry.index != i {
            allSequential = false
            break
        }
        check("indices sequential", allSequential)

        // 9. Output times are monotonically increasing
        var monotonic = true
        for i in 1..<s8.count where s8[i].outputTime <= s8[i - 1].outputTime {
            monotonic = false
            break
        }
        check("output times monotonic", monotonic)

        // 10. Frame-snapped trim bounds produce exact integer counts
        // Duration 2.5s at 10fps -> exactly 25 frames
        let s10 = VideoFrameExtractor.computeFrameSchedule(
            keepRanges: [TimeRange(start: 0.0, end: 2.5)],
            frameRate: 10.0, speedMultiplier: 1.0
        )
        check("frame-snapped exact count", s10.count == 25, "got \(s10.count)")

        // MARK: Error descriptions

        let errs: [VideoFrameExtractor.ExtractError] = [
            .sourceLoadFailed(URL(fileURLWithPath: "/tmp/x.mp4"),
                              underlying: NSError(domain: "test", code: 1)),
            .noVideoTrack(URL(fileURLWithPath: "/tmp/x.mp4")),
            .emptyKeepRanges,
            .unsupportedDuration(URL(fileURLWithPath: "/tmp/x.mp4")),
            .invalidFrameRate(-5),
            .invalidSpeedMultiplier(0),
            .invalidTargetDimensions(width: 0, height: 0),
            .frameGenerationFailed(sourceTime: 1.5, underlying: nil)
        ]
        for (i, e) in errs.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        // Note: extractFrames input validation guards (fps > 0, speed > 0,
        // dimensions >= 2, non-empty ranges) are simple enough to verify by
        // code review. Exercising them here would require bridging async
        // throws into this synchronous harness, which risks deadlock on the
        // actor executor. Full integration is covered by end-to-end runs.

        return (passed: passed, failed: failures.count, failures: failures)
    } // runAll

} // VideoFrameExtractorTests

#endif
