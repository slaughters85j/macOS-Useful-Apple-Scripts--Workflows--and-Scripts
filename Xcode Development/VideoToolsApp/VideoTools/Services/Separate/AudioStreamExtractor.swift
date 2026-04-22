import Foundation
import AVFoundation
import CoreMedia

// MARK: - AudioStreamExtractor

/// Actor that extracts the audio track from a source file into a standalone
/// WAV file using `AVAssetReader` decoding to LPCM and `AVAssetWriter`
/// writing to a WAVE container.
///
/// Replaces the Python separator's `-vn -acodec pcm_s16le -ar N -ac N` code
/// path. The extractor always produces 16-bit signed little-endian PCM at
/// the caller-supplied sample rate and channel count. CoreAudio's built-in
/// sample-rate conversion and downmixing run inside the reader; we don't
/// need to build a custom converter.
///
/// For sources without an audio track, this throws `noAudioTrack`; the
/// orchestrator is responsible for skipping audio extraction in that case
/// rather than surfacing an error, since "no audio" is a valid source
/// state, not a failure.
actor AudioStreamExtractor {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case noAudioTrack(path: String)
        case readerCreationFailed(underlying: Error)
        case readerStartFailed(underlying: Error?)
        case readerFailed(underlying: Error?)
        case writerCreationFailed(underlying: Error)
        case writerStartFailed(underlying: Error?)
        case writerFailed(underlying: Error?)
        case appendFailed(underlying: Error?)
        case cannotAddOutput
        case cannotAddInput

        var errorDescription: String? {
            switch self {
            case .noAudioTrack(let path):
                return "No audio track in '\(path)' to extract."
            case .readerCreationFailed(let err):
                return "Could not create AVAssetReader for audio: \(err.localizedDescription)"
            case .readerStartFailed(let err):
                return "Audio reader.startReading failed: \(err?.localizedDescription ?? "unknown")"
            case .readerFailed(let err):
                return "Audio reader entered failed state: \(err?.localizedDescription ?? "unknown")"
            case .writerCreationFailed(let err):
                return "Could not create AVAssetWriter for WAV output: \(err.localizedDescription)"
            case .writerStartFailed(let err):
                return "Audio writer.startWriting failed: \(err?.localizedDescription ?? "unknown")"
            case .writerFailed(let err):
                return "Audio writer entered failed state: \(err?.localizedDescription ?? "unknown")"
            case .appendFailed(let err):
                return "Failed to append audio sample: \(err?.localizedDescription ?? "unknown")"
            case .cannotAddOutput:
                return "AVAssetReader refused to add audio output."
            case .cannotAddInput:
                return "AVAssetWriter refused to add audio input."
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Extract the audio from `sourceURL` to `outputURL` as a WAV file.
    ///
    /// - Parameters:
    ///   - sourceURL: Input video / audio file.
    ///   - outputURL: Destination WAV path. Any existing file is removed.
    ///   - sampleRate: Target sample rate in Hz (e.g. 48_000, 44_100).
    ///                 CoreAudio resamples from the source rate as needed.
    ///   - channels: Target channel count (1 = mono, 2 = stereo, etc.).
    ///               CoreAudio downmixes/upmixes from source as needed.
    func extract(
        sourceURL: URL,
        outputURL: URL,
        sampleRate: Int,
        channels: Int
    ) async throws {

        // Remove any existing file.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // MARK: Load audio track
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let audioTrack = audioTracks.first else {
            throw ExportError.noAudioTrack(path: sourceURL.path)
        }

        // MARK: Build reader with LPCM decompression
        //
        // 16-bit signed little-endian PCM, interleaved. This is the format
        // that writes to a standard WAV container with no further conversion.
        // CoreAudio performs sample-rate conversion and channel remixing
        // internally when the reader settings differ from the source
        // track's native format.
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw ExportError.readerCreationFailed(underlying: error)
        }

        let lpcmSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack, outputSettings: lpcmSettings
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else {
            throw ExportError.cannotAddOutput
        }
        reader.add(readerOutput)

        // MARK: Build writer with WAVE container
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        } catch {
            throw ExportError.writerCreationFailed(underlying: error)
        }

        // Writer input with the same LPCM settings so the decoded samples
        // can be appended directly without re-encoding.
        let writerInput = AVAssetWriterInput(
            mediaType: .audio, outputSettings: lpcmSettings
        )
        writerInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(writerInput) else {
            throw ExportError.cannotAddInput
        }
        writer.add(writerInput)

        // MARK: Start
        guard reader.startReading() else {
            throw ExportError.readerStartFailed(underlying: reader.error)
        }
        guard writer.startWriting() else {
            throw ExportError.writerStartFailed(underlying: writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Pump
        do {
            try await pump(reader: reader, output: readerOutput, input: writerInput)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }

        // MARK: Finalize
        writerInput.markAsFinished()

        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.readerFailed(underlying: reader.error)
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw ExportError.writerFailed(underlying: writer.error)
        }
    } // extract

    // MARK: - Pump

    /// Drain the LPCM reader into the writer. Honors task cancellation at
    /// every await point.
    private func pump(
        reader: AVAssetReader,
        output: AVAssetReaderTrackOutput,
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
                throw ExportError.appendFailed(underlying: reader.error)
            }

            await Task.yield()
        }
    } // pump
} // AudioStreamExtractor

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `AudioStreamExtractor`.
enum AudioStreamExtractorTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        struct Dummy: Error {}
        let errors: [AudioStreamExtractor.ExportError] = [
            .noAudioTrack(path: "/x.mp4"),
            .readerCreationFailed(underlying: Dummy()),
            .readerStartFailed(underlying: nil),
            .readerFailed(underlying: nil),
            .writerCreationFailed(underlying: Dummy()),
            .writerStartFailed(underlying: nil),
            .writerFailed(underlying: nil),
            .appendFailed(underlying: nil),
            .cannotAddOutput,
            .cannotAddInput
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        print("AudioStreamExtractorTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // AudioStreamExtractorTests

#endif
