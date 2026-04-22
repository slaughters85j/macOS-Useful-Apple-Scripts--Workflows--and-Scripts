import Foundation
import AVFoundation
import CoreMedia

// MARK: - MergeReencodeExporter

/// Actor that re-encodes a pre-assembled `AVMutableComposition` into a new
/// single-file output using `AVAssetReader` + `AVAssetWriter`, with an
/// attached `AVVideoComposition` applying per-source aspect transforms.
///
/// Replaces the Python merger's `filter_complex` code path (per-input
/// scale/pad/crop + fps + audio normalization + concat). Because the caller
/// has already flattened all N inputs into one composition with one video
/// track and one audio track, this exporter only needs to pump samples
/// through one reader-output-to-writer-input pair per media type.
///
/// Compared to the splitter's `SegmentReencodeExporter`, this is simpler:
/// - No per-segment PTS offset — the composition timeline already starts
///   at zero.
/// - No custom fps resampler — `AVVideoComposition.frameDuration` emits the
///   target frame cadence automatically via the reader's video composition
///   output.
/// - Audio is re-encoded to AAC (stereo, 48 kHz, 192 kbps) rather than
///   passed through, matching the Python merger's normalization.
///
/// Video encoder settings are supplied by the caller
/// (`SplitEncoderSettings.videoOutputSettings`), which produces the same
/// HEVC-constant-quality / H.264-bitrate dictionary used by the splitter's
/// re-encode path.
actor MergeReencodeExporter {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case readerCreationFailed(underlying: Error)
        case readerStartFailed(underlying: Error?)
        case readerFailed(underlying: Error?)
        case writerCreationFailed(underlying: Error)
        case writerStartFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        case videoAppendFailed(underlying: Error?)
        case audioAppendFailed(underlying: Error?)
        case cannotAddOutput(kind: String)

        var errorDescription: String? {
            switch self {
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
                return "Failed to append merged video sample: \(err?.localizedDescription ?? "unknown")"
            case .audioAppendFailed(let err):
                return "Failed to append merged audio sample: \(err?.localizedDescription ?? "unknown")"
            case .cannotAddOutput(let kind):
                return "AVAssetReader refused to add \(kind) output."
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Re-encode the composition to `outputURL`.
    ///
    /// - Parameters:
    ///   - composition: The assembled composition from `CompositionBuilder.build`.
    ///   - videoTracks: Pre-loaded video tracks from the composition. Loading
    ///                  tracks in the caller avoids sending `composition` across
    ///                  actor isolation boundaries (Swift 6 strict concurrency).
    ///   - audioTracks: Pre-loaded audio tracks from the composition.
    ///   - videoComposition: The matching `AVVideoComposition` with per-instruction
    ///                       layer transforms and target `frameDuration`.
    ///   - outputURL: Destination path. Any existing file is removed first.
    ///   - fileType: Output container (`.mp4` or `.mov`).
    ///   - videoOutputSettings: From `SplitEncoderSettings.videoOutputSettings`.
    ///                          Includes codec, quality, and target dimensions.
    func export(
        composition: AVComposition,
        videoTracks: [AVAssetTrack],
        audioTracks: [AVAssetTrack],
        videoComposition: AVVideoComposition,
        outputURL: URL,
        fileType: AVFileType,
        videoOutputSettings: [String: Any]
    ) async throws {

        // Remove any existing file.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // MARK: Build reader
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw ExportError.readerCreationFailed(underlying: error)
        }

        // Video output goes through an AVAssetReaderVideoCompositionOutput
        // so the attached videoComposition's layer transforms are applied
        // by the system before we see the frames. The pixel format is 420v
        // for zero-copy into the VideoToolbox encoder.
        let videoOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: videoTracks,
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            ]
        )
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else {
            throw ExportError.cannotAddOutput(kind: "video composition")
        }
        reader.add(videoOutput)

        // Audio output is optional — only present if any source had audio,
        // which CompositionBuilder encodes as "audio track exists on the
        // composition". Decompress to LPCM (float32 stereo) so the writer
        // can re-encode to AAC.
        var audioOutput: AVAssetReaderAudioMixOutput? = nil
        if let firstAudio = audioTracks.first {
            _ = firstAudio  // silence unused-binding warning in some build configs
            let lpcmSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2
            ]
            let out = AVAssetReaderAudioMixOutput(
                audioTracks: audioTracks, audioSettings: lpcmSettings
            )
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) {
                reader.add(out)
                audioOutput = out
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
        // The videoComposition has already applied per-source transforms and
        // rendered to the target `renderSize`, so the writer input doesn't
        // need its own transform. Passing .identity is defensive.
        videoInput.transform = .identity
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerStartFailed(underlying: nil)
        }
        writer.add(videoInput)

        // AAC re-encode for audio: stereo, 48 kHz, 192 kbps. Matches the
        // legacy ffmpeg aformat+aresample chain.
        var audioInput: AVAssetWriterInput? = nil
        if audioOutput != nil {
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000
            ]
            let ai = AVAssetWriterInput(
                mediaType: .audio, outputSettings: aacSettings
            )
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

        // MARK: Pump
        do {
            try await pumpVideo(
                reader: reader, output: videoOutput, input: videoInput
            )
            if let audioInput, let audioOutput {
                try await pumpAudio(
                    reader: reader, output: audioOutput, input: audioInput
                )
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        // MARK: Finalize
        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.readerFailed(underlying: reader.error)
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(underlying: writer.error)
        }
    } // export

    // MARK: - Pumps

    /// Video pump. Pulls rendered frames from the video composition output
    /// (which has already applied the layer-transform pipeline) and appends
    /// them to the writer input.
    ///
    /// No retiming is needed — composition timeline already starts at zero
    /// and the video composition's `frameDuration` governs cadence.
    private func pumpVideo(
        reader: AVAssetReader,
        output: AVAssetReaderVideoCompositionOutput,
        input: AVAssetWriterInput
    ) async throws {
        while true {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2 ms
                try Task.checkCancellation()
            }

            guard let sample = output.copyNextSampleBuffer() else {
                return // EOF for this track
            }
            if !input.append(sample) {
                throw ExportError.videoAppendFailed(underlying: reader.error)
            }

            await Task.yield()
        }
    } // pumpVideo

    /// Audio pump. LPCM samples from the audio mix output get handed to the
    /// writer input, which re-encodes them to AAC per its output settings.
    private func pumpAudio(
        reader: AVAssetReader,
        output: AVAssetReaderAudioMixOutput,
        input: AVAssetWriterInput
    ) async throws {
        while true {
            try Task.checkCancellation()

            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000) // 2 ms
                try Task.checkCancellation()
            }

            guard let sample = output.copyNextSampleBuffer() else {
                return
            }
            if !input.append(sample) {
                throw ExportError.audioAppendFailed(underlying: reader.error)
            }

            await Task.yield()
        }
    } // pumpAudio
} // MergeReencodeExporter

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `MergeReencodeExporter`.
/// End-to-end correctness is verified through the UI.
enum MergeReencodeExporterTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        struct Dummy: Error {}
        let errors: [MergeReencodeExporter.ExportError] = [
            .readerCreationFailed(underlying: Dummy()),
            .readerStartFailed(underlying: nil),
            .readerFailed(underlying: nil),
            .writerCreationFailed(underlying: Dummy()),
            .writerStartFailed(underlying: nil),
            .writerFailed(underlying: nil),
            .videoAppendFailed(underlying: nil),
            .audioAppendFailed(underlying: nil),
            .cannotAddOutput(kind: "video")
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        print("MergeReencodeExporterTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // MergeReencodeExporterTests

#endif
