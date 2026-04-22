import Foundation
import AVFoundation

// MARK: - VideoSeparator

/// Top-level orchestrator for the native video-audio separator.
///
/// Replaces the legacy `PythonRunner.runSeparator` subprocess path with a
/// pure AVFoundation pipeline. Consumes a `SeparateConfig`, probes each
/// input, creates a `<stem>_separated/` output folder, and dispatches two
/// sub-tasks per input: video-only passthrough (via `VideoStreamExtractor`)
/// and audio-to-WAV (via `AudioStreamExtractor`).
///
/// ### Event shape
///
/// Matches the legacy Python separator's event contract so the UI's
/// progress tracking stays unchanged:
/// - `start(totalFiles: N, hardwareAcceleration: true)`
/// - Per file: `progress` → `fileStart` → two `segmentStart/Complete` pairs
///   (segment 1 = video, segment 2 = audio, total = 2) → `fileComplete`.
/// - `complete(totalFiles: N, successful: k, failed: N-k)`
///
/// ### Concurrency
///
/// Across the batch, up to `parallelJobs` files process concurrently via a
/// `TaskGroup`. Within each file, video and audio extraction run
/// concurrently via `async let`. Task cancellation propagates through
/// `try await`.
///
/// If a source has no audio track, the audio extraction is skipped
/// silently (not treated as a failure); the `fileComplete` event still
/// fires with success=true.
actor VideoSeparator {

    // MARK: - Dependencies

    private let videoExtractor: VideoStreamExtractor
    private let audioExtractor: AudioStreamExtractor

    init(
        videoExtractor: VideoStreamExtractor = VideoStreamExtractor(),
        audioExtractor: AudioStreamExtractor = AudioStreamExtractor()
    ) {
        self.videoExtractor = videoExtractor
        self.audioExtractor = audioExtractor
    } // init

    // MARK: - Errors

    enum SeparateError: Error, LocalizedError {
        case configInvalid(reason: String)
        case outputDirectoryCreationFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .configInvalid(let reason):
                return "SeparateConfig is invalid: \(reason)"
            case .outputDirectoryCreationFailed(let path, let err):
                return "Could not create output directory \(path): \(err.localizedDescription)"
            }
        } // errorDescription
    } // SeparateError

    // MARK: - Public API

    /// Run a batch separation per the provided config.
    ///
    /// Emits `start` once, then per-file progress + lifecycle events, then
    /// `complete`. Config validation errors throw synchronously. Per-file
    /// failures surface as `fileError` and do not abort the batch.
    func separate(
        config: SeparateConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        // MARK: Pre-flight
        if let err = config.validationError {
            onEvent(.error(message: err))
            throw SeparateError.configInvalid(reason: err)
        }

        let totalFiles = config.inputs.count
        onEvent(.start(totalFiles: totalFiles, hardwareAcceleration: true))

        let concurrencyCap = max(1, config.parallelJobs)

        // Counter for successful/failed tallies across concurrent tasks.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var successful = 0
            private var failed = 0
            func recordSuccess() {
                lock.lock(); defer { lock.unlock() }; successful += 1
            }
            func recordFailure() {
                lock.lock(); defer { lock.unlock() }; failed += 1
            }
            func snapshot() -> (Int, Int) {
                lock.lock(); defer { lock.unlock() }; return (successful, failed)
            }
        }
        let counter = Counter()

        try await withThrowingTaskGroup(of: Void.self) { group in
            var launched = 0
            var processedIndex = 0

            func launch(index: Int) {
                let url = config.inputs[index]
                group.addTask { [videoExtractor, audioExtractor] in
                    let filename = url.lastPathComponent
                    // Per-file progress event (advanced strictly in launch order
                    // rather than completion order — this mirrors the legacy
                    // Python separator's progress-event semantics).
                    onEvent(.progress(
                        currentFile: index + 1,
                        totalFiles: totalFiles,
                        filename: filename
                    ))
                    onEvent(.fileStart(file: filename, path: url.path))

                    do {
                        try await Self.separateOne(
                            url: url,
                            config: config,
                            videoExtractor: videoExtractor,
                            audioExtractor: audioExtractor,
                            onEvent: onEvent
                        )
                        counter.recordSuccess()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        onEvent(.fileError(
                            file: filename, error: error.localizedDescription
                        ))
                        counter.recordFailure()
                    }
                }
            }

            // Seed the group up to the concurrency cap.
            while launched < min(concurrencyCap, totalFiles) {
                launch(index: launched)
                launched += 1
            }

            // Drain as tasks complete, launching replacements until all
            // inputs have been dispatched.
            while processedIndex < totalFiles {
                _ = try await group.next()
                processedIndex += 1
                if launched < totalFiles {
                    launch(index: launched)
                    launched += 1
                }
            }
        }

        let (successful, failed) = counter.snapshot()
        onEvent(.complete(
            totalFiles: totalFiles, successful: successful, failed: failed
        ))
    } // separate

    // MARK: - Per-file pipeline

    /// Separate one file. Static so it doesn't capture `self` inside the
    /// TaskGroup closures (avoids Swift 6 sending-closure lint).
    private static func separateOne(
        url: URL,
        config: SeparateConfig,
        videoExtractor: VideoStreamExtractor,
        audioExtractor: AudioStreamExtractor,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        let filename = url.lastPathComponent
        let stem = url.deletingPathExtension().lastPathComponent
        let sourceExt = url.pathExtension
        let fileType = SegmentPassthroughExporter.fileType(forExtension: sourceExt) ?? .mp4

        // MARK: Output folder
        let outputDir = url
            .deletingLastPathComponent()
            .appendingPathComponent("\(stem)_separated", isDirectory: true)
        if !FileManager.default.fileExists(atPath: outputDir.path) {
            do {
                try FileManager.default.createDirectory(
                    at: outputDir, withIntermediateDirectories: true
                )
            } catch {
                throw SeparateError.outputDirectoryCreationFailed(
                    path: outputDir.path, underlying: error
                )
            }
        }

        // MARK: Audio track presence check
        //
        // We run this probe up front so the file's segment count is known
        // before segment events fire. Files with no audio still get one
        // `segmentStart/Complete` pair (video only) with `total = 1`, so
        // the UI's progress-strip increments correctly.
        let asset = AVURLAsset(url: url)
        let hasAudio: Bool = (try? await asset.loadTracks(withMediaType: .audio))?
            .isEmpty == false
        let totalSegments = hasAudio ? 2 : 1

        // MARK: Extract video and (optionally) audio concurrently

        let videoURL = outputDir.appendingPathComponent("\(stem)_video.\(sourceExt)")
        let audioURL = outputDir.appendingPathComponent("\(stem)_audio.wav")
        let sampleRate = config.effectiveSampleRate(for: filename)
        let channels = config.audioChannels

        // Video extraction is always run; audio only when a track exists.
        async let videoResult: Void = {
            onEvent(.segmentStart(file: filename, segment: 1, total: totalSegments))
            try await videoExtractor.extract(
                sourceURL: url, outputURL: videoURL, fileType: fileType
            )
            onEvent(.segmentComplete(
                file: filename, segment: 1, total: totalSegments,
                output: videoURL.path
            ))
        }()

        async let audioResult: Void = {
            if hasAudio {
                onEvent(.segmentStart(
                    file: filename, segment: 2, total: totalSegments
                ))
                try await audioExtractor.extract(
                    sourceURL: url, outputURL: audioURL,
                    sampleRate: sampleRate, channels: channels
                )
                onEvent(.segmentComplete(
                    file: filename, segment: 2, total: totalSegments,
                    output: audioURL.path
                ))
            }
        }()

        // Await both. Either throwing cancels the file; per-file errors
        // surface to the TaskGroup's per-file catch.
        try await videoResult
        try await audioResult

        onEvent(.fileComplete(
            file: filename,
            success: true,
            outputDir: outputDir.path,
            segmentsCompleted: totalSegments,
            segmentsTotal: totalSegments
        ))
    } // separateOne
} // VideoSeparator actor

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `VideoSeparator`.
enum VideoSeparatorTests {

    @discardableResult
    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        var passed = 0
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failures.append(name) }
        } // check

        // MARK: Error descriptions
        let errors: [VideoSeparator.SeparateError] = [
            .configInvalid(reason: "x"),
            .outputDirectoryCreationFailed(
                path: "/x", underlying: NSError(domain: "t", code: 1)
            )
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        // MARK: Async rejection of invalid config

        final class ResultHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var rejected = false
            func setRejected() {
                lock.lock(); defer { lock.unlock() }; rejected = true
            }
            func wasRejected() -> Bool {
                lock.lock(); defer { lock.unlock() }; return rejected
            }
        }
        let holder = ResultHolder()
        let sem = DispatchSemaphore(value: 0)

        Task.detached {
            let separator = VideoSeparator()
            let empty = SeparateConfig(
                inputs: [],
                globalSampleRate: 48_000,
                perFileSampleRate: [:],
                usePerFileSampleRate: false,
                audioChannels: 2,
                parallelJobs: 4
            )
            do {
                try await separator.separate(config: empty, onEvent: { _ in })
            } catch VideoSeparator.SeparateError.configInvalid {
                holder.setRejected()
            } catch {
                // wrong type
            }
            sem.signal()
        }
        sem.wait()
        check("empty-inputs config rejected with configInvalid",
              holder.wasRejected())

        print("VideoSeparatorTests: \(passed) passed, \(failures.count) failed")
        for name in failures {
            print("  FAILED: \(name)")
        }
        return (passed, failures.count, failures)
    } // runAll
} // VideoSeparatorTests

#endif
