import Foundation
import AVFoundation
import CoreMedia

// MARK: - SegmentReencodeExporter

/// Actor that exports one time range of a source asset to an output file by
/// reading raw samples with `AVAssetReader` and re-encoding through an
/// `AVAssetWriter`.
///
/// Replaces the Python splitter's re-encode code paths (`-c:v h264_videotoolbox`
/// or `-c:v hevc_videotoolbox`, optionally with `-vf fps=N`). The caller
/// supplies a pre-built `outputSettings` dictionary from
/// `SplitEncoderSettings.videoOutputSettings(...)` and an optional target
/// frame rate for fps conversion; this type performs the actual read-transcode-
/// write pump.
///
/// ### Pipeline
///
/// 1. Build an `AVAssetReader` with the supplied `timeRange`. The reader
///    produces decoded video pixel buffers (hardware decode via VideoToolbox
///    when the source codec is supported) and, if present, raw audio sample
///    buffers in their source compressed format for passthrough.
///
/// 2. Build an `AVAssetWriter` with a video input configured from
///    `videoOutputSettings` (codec, bitrate / quality, dimensions). Audio is
///    passed through untouched so there's no audio re-encode cost. The
///    source's `preferredTransform` is copied onto the video writer input
///    so rotated / portrait sources stay oriented correctly.
///
/// 3. Start writing at source time zero. Each sample buffer is re-clocked
///    segment-relative via `CMSampleBufferCreateCopyWithNewTiming` so the
///    output file starts at PTS 0 regardless of where the segment sits in
///    the source.
///
/// 4. If `targetFrameRate` differs from the source's nominal frame rate,
///    resample by nearest-past source frame: step the output timeline in
///    `1 / targetFrameRate` increments, picking the most recent source
///    buffer at each step. Duplicates or drops frames as needed, matching
///    ffmpeg `-vf fps=N` behavior.
///
/// 5. Finalize and report reader / writer failure modes as typed errors.
///
/// ### Concurrency
///
/// Everything runs on the actor. Sample-buffer handoff between reader and
/// writer is synchronous within the pump loop, with `Task.yield()` between
/// batches and a short `Task.sleep` when the writer input is not ready.
/// Cancellation is checked at every yield point. AVFoundation reference
/// types are held only on the actor, so their non-Sendable status is not
/// a concern here.
actor SegmentReencodeExporter {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case noVideoTrack
        case readerCreationFailed(underlying: Error)
        case readerStartFailed(underlying: Error?)
        case readerFailed(underlying: Error?)
        case writerCreationFailed(underlying: Error)
        case writerStartFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        case videoAppendFailed(underlying: Error?)
        case audioAppendFailed(underlying: Error?)
        case sampleRetimingFailed(status: OSStatus)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack:
                return "Source asset has no video track."
            case .readerCreationFailed(let err):
                return "Could not create AVAssetReader: \(err.localizedDescription)"
            case .readerStartFailed(let err):
                return "AVAssetReader.startReading failed: \(err?.localizedDescription ?? "unknown")"
            case .readerFailed(let err):
                return "AVAssetReader entered failed state: \(err?.localizedDescription ?? "unknown")"
            case .writerCreationFailed(let err):
                return "Could not create AVAssetWriter: \(err.localizedDescription)"
            case .writerStartFailed(let err):
                return "AVAssetWriter.startWriting failed: \(err?.localizedDescription ?? "unknown")"
            case .writerFailed(let err):
                return "AVAssetWriter entered failed state: \(err?.localizedDescription ?? "unknown")"
            case .videoAppendFailed(let err):
                return "Failed to append video sample: \(err?.localizedDescription ?? "unknown")"
            case .audioAppendFailed(let err):
                return "Failed to append audio sample: \(err?.localizedDescription ?? "unknown")"
            case .sampleRetimingFailed(let status):
                return "CMSampleBufferCreateCopyWithNewTiming failed (status \(status))."
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Export one segment by reading the given time range from `asset` and
    /// re-encoding into `outputURL`.
    ///
    /// - Parameters:
    ///   - asset: The source asset.
    ///   - timeRange: Source-timeline range to export.
    ///   - outputURL: Destination URL. An existing file at this path is
    ///                removed before writing begins.
    ///   - fileType: Output container (`.mp4` or `.mov`).
    ///   - videoOutputSettings: Settings dictionary for the video
    ///                          `AVAssetWriterInput`, produced by
    ///                          `SplitEncoderSettings.videoOutputSettings`.
    ///   - targetFrameRate: If `nil`, emit frames at the source's natural
    ///                      cadence (one-to-one retime). If non-nil and
    ///                      different from the source nominal frame rate,
    ///                      resample by nearest-past source frame.
    ///   - preferredTransform: The source video track's `preferredTransform`.
    ///                         Applied to the writer input so rotation is
    ///                         preserved in the output container.
    ///   - includeAudio: When true, the first audio track (if any) is
    ///                   passed through untouched.
    /// - Throws: `ExportError` on reader / writer failure,
    ///           `CancellationError` if the parent Task is cancelled.
    func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        outputURL: URL,
        fileType: AVFileType,
        videoOutputSettings: [String: Any],
        targetFrameRate: Double?,
        preferredTransform: CGAffineTransform,
        includeAudio: Bool
    ) async throws {

        // Remove any existing file: AVAssetWriter refuses to overwrite.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // MARK: Load tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack
        }
        let sourceFPS = try await videoTrack.load(.nominalFrameRate)

        // Audio is optional. `includeAudio == false` disables it even if
        // the source has audio, matching future callers who may want a
        // video-only segment.
        let audioTrack: AVAssetTrack? = includeAudio
            ? try await asset.loadTracks(withMediaType: .audio).first
            : nil

        // MARK: Build reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerCreationFailed(underlying: error)
        }
        reader.timeRange = timeRange

        // Decoded pixel format for the video reader. 420 bi-planar video-range
        // (`420v`) is the format VideoToolbox hardware decoders produce and
        // VideoToolbox encoders accept directly; this keeps the data path
        // zero-copy on Apple Silicon.
        let videoReaderSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        let videoReaderOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: videoReaderSettings
        )
        videoReaderOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoReaderOutput) else {
            throw ExportError.readerStartFailed(underlying: nil)
        }
        reader.add(videoReaderOutput)

        // Audio passthrough: outputSettings = nil gives us the source's
        // compressed audio samples, which we hand straight to a writer input
        // also configured for passthrough.
        var audioReaderOutput: AVAssetReaderTrackOutput? = nil
        if let audioTrack {
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioReaderOutput = out
            }
        }

        // MARK: Build writer
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw ExportError.writerCreationFailed(underlying: error)
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoOutputSettings
        )
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerStartFailed(underlying: nil)
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput? = nil
        if audioReaderOutput != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) {
                writer.add(ai)
                audioInput = ai
            }
        }

        // MARK: Start reader and writer
        guard reader.startReading() else {
            throw ExportError.readerStartFailed(underlying: reader.error)
        }
        guard writer.startWriting() else {
            throw ExportError.writerStartFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Pump video
        // Decide between straight retime and fps resampling. A difference of
        // less than 0.01 fps is treated as "same fps" to absorb float noise
        // in nominalFrameRate.
        let needsResampling: Bool = {
            guard let target = targetFrameRate, target > 0 else { return false }
            return abs(target - Double(sourceFPS)) > 0.01
        }()

        do {
            if needsResampling, let target = targetFrameRate {
                try await pumpVideoResampled(
                    reader: reader,
                    output: videoReaderOutput,
                    input: videoInput,
                    segmentStart: timeRange.start,
                    segmentDuration: timeRange.duration,
                    targetFrameRate: target
                )
            } else {
                try await pumpVideoRetimed(
                    reader: reader,
                    output: videoReaderOutput,
                    input: videoInput,
                    segmentStart: timeRange.start
                )
            }
        } catch {
            // Ensure reader and writer wind down even if the pump failed.
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        // MARK: Pump audio
        if let audioInput, let audioReaderOutput {
            do {
                try await pumpAudio(
                    reader: reader,
                    output: audioReaderOutput,
                    input: audioInput,
                    segmentStart: timeRange.start
                )
            } catch {
                reader.cancelReading()
                writer.cancelWriting()
                throw error
            }
        }

        // MARK: Finalize
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        // Surface reader-side failures that only manifest at EOF (e.g. a
        // corrupt trailing sample). Do this before finishWriting so we don't
        // ship a half-bad file.
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.readerFailed(underlying: reader.error)
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(underlying: writer.error)
        }
    } // export

    // MARK: - Retime-only video pump

    /// Pump source video samples into the writer, subtracting `segmentStart`
    /// from every sample's presentation time so the output stream starts at 0.
    ///
    /// This is the common case (target fps matches or is unspecified). No
    /// frame-rate conversion is applied; frame cadence is whatever the source
    /// delivers.
    private func pumpVideoRetimed(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        segmentStart: CMTime
    ) async throws {
        while true {
            try Task.checkCancellation()

            // Wait for the writer input to be ready. Short polling interval
            // keeps the reader drained without burning CPU.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms
                try Task.checkCancellation()
            }

            guard let sample = output.copyNextSampleBuffer() else {
                return // EOF for this track
            }

            let retimed = try retime(sample: sample, offset: segmentStart)
            if !input.append(retimed) {
                throw ExportError.videoAppendFailed(underlying: reader.error)
            }

            // Yield periodically so other Tasks (and the writer's internal
            // queue) get a chance to run on busy batches.
            await Task.yield()
        }
    } // pumpVideoRetimed

    // MARK: - Resampled video pump

    /// Pump source video samples with a frame-rate conversion applied.
    ///
    /// Strategy: walk the output timeline in `1 / targetFrameRate` steps.
    /// For each target time, pick the most-recently-decoded source buffer
    /// whose PTS (relative to `segmentStart`) is less than or equal to the
    /// target. Emit that buffer with a new PTS = target time and duration =
    /// one target frame. This duplicates source frames when target fps is
    /// higher than source fps, and drops them when it's lower.
    ///
    /// The output timeline is bounded by `segmentDuration` so we don't emit
    /// frames past the segment's end. A target frame rate of 30 on a 2 s
    /// segment yields 60 output frames at PTS 0, 1/30, 2/30, ..., 59/30.
    private func pumpVideoResampled(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        segmentStart: CMTime,
        segmentDuration: CMTime,
        targetFrameRate: Double
    ) async throws {

        // Compute the number of output frames. Use floor to avoid emitting a
        // short trailing frame that extends past the segment end.
        let targetFps = max(1.0, targetFrameRate)
        let outputFrameDuration = 1.0 / targetFps
        let totalFrames = max(1, Int((segmentDuration.seconds * targetFps).rounded(.down)))

        // Prefetch the first source buffer to seed the "most recent" slot.
        var currentBuffer: CMSampleBuffer? = output.copyNextSampleBuffer()
        var nextBuffer: CMSampleBuffer? = output.copyNextSampleBuffer()

        // Helper: source-relative PTS of a buffer, in seconds. `nil` when the
        // buffer is `nil` or its PTS is invalid.
        func relativeSeconds(_ buffer: CMSampleBuffer?) -> Double? {
            guard let buffer else { return nil }
            let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
            guard pts.isValid else { return nil }
            return CMTimeSubtract(pts, segmentStart).seconds
        }

        for frameIndex in 0 ..< totalFrames {
            try Task.checkCancellation()

            let targetSeconds = Double(frameIndex) * outputFrameDuration

            // Advance the source cursor while the next buffer's start is at or
            // before our target time. This keeps `currentBuffer` as the most
            // recent source frame not in the future.
            while let next = nextBuffer,
                  let nextStart = relativeSeconds(next),
                  nextStart <= targetSeconds {
                currentBuffer = next
                nextBuffer = output.copyNextSampleBuffer()
            }

            guard let source = currentBuffer else {
                // Reader ran dry before we reached the end. Let the writer
                // finish up; the output will be short by the remaining frames.
                return
            }

            // Wait for writer readiness before appending.
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms
                try Task.checkCancellation()
            }

            // Build a new sample buffer whose PTS is at the target time and
            // whose duration is exactly one output frame interval.
            let newPTS = CMTime(seconds: targetSeconds, preferredTimescale: 90_000)
            let newDuration = CMTime(
                seconds: outputFrameDuration, preferredTimescale: 90_000
            )
            let retimed = try retime(
                sample: source,
                absolutePTS: newPTS,
                duration: newDuration
            )
            if !input.append(retimed) {
                throw ExportError.videoAppendFailed(underlying: reader.error)
            }

            await Task.yield()
        }
    } // pumpVideoResampled

    // MARK: - Audio pump

    /// Pump audio samples passthrough, subtracting `segmentStart` so the
    /// output stream starts at PTS 0 just like the video track.
    private func pumpAudio(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
        input: AVAssetWriterInput,
        segmentStart: CMTime
    ) async throws {
        while true {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2ms
                try Task.checkCancellation()
            }

            guard let sample = output.copyNextSampleBuffer() else {
                return
            }

            let retimed = try retime(sample: sample, offset: segmentStart)
            if !input.append(retimed) {
                throw ExportError.audioAppendFailed(underlying: reader.error)
            }

            await Task.yield()
        }
    } // pumpAudio

    // MARK: - Retiming helpers

    /// Produce a new sample buffer with timing shifted by `-offset` so that
    /// sample buffers sliced out of the middle of a source begin at PTS 0.
    private nonisolated func retime(
        sample: CMSampleBuffer,
        offset: CMTime
    ) throws -> CMSampleBuffer {
        // Extract all per-sample timing entries, subtract offset from each
        // PTS and DTS, and build a replacement buffer carrying the new times.
        var count: CMItemCount = 0
        _ = CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        )
        var timings = [CMSampleTimingInfo](
            repeating: CMSampleTimingInfo(), count: max(1, Int(count))
        )
        var filled: CMItemCount = 0
        let getStatus = CMSampleBufferGetSampleTimingInfoArray(
            sample,
            entryCount: count,
            arrayToFill: &timings,
            entriesNeededOut: &filled
        )
        if getStatus != noErr {
            throw ExportError.sampleRetimingFailed(status: getStatus)
        }

        for i in 0 ..< Int(filled) {
            if timings[i].presentationTimeStamp.isValid {
                timings[i].presentationTimeStamp =
                    CMTimeSubtract(timings[i].presentationTimeStamp, offset)
            }
            if timings[i].decodeTimeStamp.isValid {
                timings[i].decodeTimeStamp =
                    CMTimeSubtract(timings[i].decodeTimeStamp, offset)
            }
        }

        var out: CMSampleBuffer?
        let copyStatus = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: filled,
            sampleTimingArray: &timings,
            sampleBufferOut: &out
        )
        if copyStatus != noErr || out == nil {
            throw ExportError.sampleRetimingFailed(status: copyStatus)
        }
        return out!
    } // retime(sample:offset:)

    /// Produce a new sample buffer with absolute PTS and duration, used by
    /// the resampling pump to assign synthesized target-timeline times.
    private nonisolated func retime(
        sample: CMSampleBuffer,
        absolutePTS: CMTime,
        duration: CMTime
    ) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: absolutePTS,
            decodeTimeStamp: .invalid
        )
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &out
        )
        if status != noErr || out == nil {
            throw ExportError.sampleRetimingFailed(status: status)
        }
        return out!
    } // retime(sample:absolutePTS:duration:)

} // SegmentReencodeExporter

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SegmentReencodeExporter`.
/// Exercises error descriptions only; the real work (reader + writer pump)
/// is validated by running the full splitter against a test clip.
enum SegmentReencodeExporterTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        struct Dummy: Error {}
        let errors: [SegmentReencodeExporter.ExportError] = [
            .noVideoTrack,
            .readerCreationFailed(underlying: Dummy()),
            .readerStartFailed(underlying: nil),
            .readerFailed(underlying: nil),
            .writerCreationFailed(underlying: Dummy()),
            .writerStartFailed(underlying: nil),
            .writerFailed(underlying: nil),
            .videoAppendFailed(underlying: nil),
            .audioAppendFailed(underlying: nil),
            .sampleRetimingFailed(status: -12345)
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        print("SegmentReencodeExporterTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SegmentReencodeExporterTests

#endif
