import Foundation
import AVFoundation
import CoreMedia

// MARK: - SettingsBox

/// Sendable wrapper for a `[String: Any]` video-encoder settings dictionary.
///
/// `[String: Any]` is not `Sendable` because `Any` is unconstrained. In
/// practice, AVFoundation encoder-settings dictionaries contain only `NSNumber`
/// and `NSString` values, which are immutable after construction. The box
/// captures this intent at the type level so the value can cross actor and
/// TaskGroup sending boundaries without spurious Swift 6 data-race warnings.
private final class SettingsBox: @unchecked Sendable {
    let value: [String: Any]
    init(_ v: [String: Any]) { value = v }
} // SettingsBox

// MARK: - VideoSplitter

/// Top-level orchestrator for the native video splitter.
///
/// Replaces the legacy `PythonRunner.runSplitter` subprocess path with a pure
/// AVFoundation pipeline. Consumes a `SplitConfig`, probes each source asset,
/// decides between passthrough and re-encode per segment, dispatches up to
/// `parallelJobs` segment exports concurrently within each file, and emits
/// `ProcessingEvent` values through a caller-supplied closure.
///
/// ### Routing
///
/// - `codec == .copy` with no fps override (or an override that matches the
///   source nominal fps) routes through `SegmentPassthroughExporter`.
/// - Anything else routes through `SegmentReencodeExporter`. Note that an
///   fps override with `codec == .copy` still forces re-encode because
///   passthrough cannot change frame rate.
///
/// ### Concurrency
///
/// Files are processed serially within one call. Within each file, segment
/// exports run concurrently with an upper bound of `config.parallelJobs`
/// via a `TaskGroup`. Task cancellation propagates through `try await` at
/// every await point. On per-file failure, the error is surfaced as a
/// `fileError` event and the batch continues with the next input.
actor VideoSplitter {

    // MARK: - Dependencies

    private let passthroughExporter: SegmentPassthroughExporter
    private let reencodeExporter: SegmentReencodeExporter

    init(
        passthroughExporter: SegmentPassthroughExporter = SegmentPassthroughExporter(),
        reencodeExporter: SegmentReencodeExporter = SegmentReencodeExporter()
    ) {
        self.passthroughExporter = passthroughExporter
        self.reencodeExporter = reencodeExporter
    } // init

    // MARK: - Errors

    enum SplitError: Error, LocalizedError {
        case configInvalid(reason: String)
        case assetHasNoVideoTrack(path: String)
        case outputFolderCreationFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .configInvalid(let reason):
                return "SplitConfig is invalid: \(reason)"
            case .assetHasNoVideoTrack(let path):
                return "No video track in \(path)."
            case .outputFolderCreationFailed(let path, let err):
                return "Could not create output folder \(path): \(err.localizedDescription)"
            }
        } // errorDescription
    } // SplitError

    // MARK: - Public API

    /// Run a batch split per the provided config.
    ///
    /// Emits `start` once, then per-file progress + lifecycle events, then a
    /// single `complete` event at the end. Catastrophic failures (invalid
    /// config) throw synchronously; per-file failures are reported via
    /// `fileError` and do not abort the batch.
    func split(
        config: SplitConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        // MARK: Pre-flight
        if let err = config.validationError {
            onEvent(.error(message: err))
            throw SplitError.configInvalid(reason: err)
        }

        let totalFiles = config.inputs.count
        // The native path always uses VideoToolbox when re-encoding, so we
        // advertise hardware acceleration unconditionally (even for the
        // passthrough path, where no encoding happens at all).
        onEvent(.start(totalFiles: totalFiles, hardwareAcceleration: true))

        var successful = 0
        var failed = 0

        for (i, url) in config.inputs.enumerated() {
            try Task.checkCancellation()

            let filename = url.lastPathComponent
            onEvent(.progress(currentFile: i + 1, totalFiles: totalFiles, filename: filename))
            onEvent(.fileStart(file: filename, path: url.path))

            do {
                try await splitOne(url: url, config: config, onEvent: onEvent)
                successful += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                onEvent(.fileError(file: filename, error: error.localizedDescription))
                failed += 1
            }
        }

        onEvent(.complete(totalFiles: totalFiles, successful: successful, failed: failed))
    } // split

    // MARK: - Per-file pipeline

    /// Execute the full probe-plan-dispatch-finalize pipeline for one input.
    private func splitOne(
        url: URL,
        config: SplitConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {

        let filename = url.lastPathComponent

        // MARK: Probe
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw SplitError.assetHasNoVideoTrack(path: url.path)
        }
        // Load these once and reuse across all segment exports for this file.
        let sourceFPS = try await videoTrack.load(.nominalFrameRate)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let estimatedBitrate = Int(try await videoTrack.load(.estimatedDataRate))
        let naturalSize = try await videoTrack.load(.naturalSize)

        // MARK: Plan segments
        let ranges = SplitSegmentCalculator.segmentRanges(
            sourceDuration: duration,
            method: config.method,
            splitValue: config.splitValue
        )
        guard !ranges.isEmpty else {
            // Not an error: a zero-duration source produces zero segments. Still
            // report a successful file completion with zero segments.
            onEvent(.fileComplete(
                file: filename, success: true, outputDir: nil,
                segmentsCompleted: 0, segmentsTotal: 0
            ))
            return
        }

        // MARK: Resolve output folder
        let outputDir = try resolveOutputFolder(for: url, mode: config.outputFolderMode)
        let outputExt = url.pathExtension
        let fileType = SegmentPassthroughExporter.fileType(forExtension: outputExt) ?? .mp4

        // MARK: Decide route and build video output settings once
        let effectiveFrameRate = config.effectiveFrameRate(for: filename)
        let fpsOverrideDiffers: Bool = {
            guard effectiveFrameRate > 0 else { return false }
            return abs(effectiveFrameRate - Double(sourceFPS)) > 0.01
        }()
        let forcesReencode = fpsOverrideDiffers
        let routeIsReencode = (config.codec != .copy) || forcesReencode

        // Build the video encoder settings dict once per file. `SplitEncoderSettings`
        // handles the copy-codec guard by returning an empty dict; when the fps
        // override forces re-encode with `.copy`, we default-fill to H.264 so
        // the writer has a concrete codec.
        let settingsCodec: OutputCodec = (config.codec == .copy && forcesReencode)
            ? .h264
            : config.codec
        let videoOutputSettings: [String: Any] = routeIsReencode
            ? SplitEncoderSettings.videoOutputSettings(
                codec: settingsCodec,
                qualityMode: config.qualityMode,
                qualitySlider: config.qualityValue,
                sourceBitrate: estimatedBitrate,
                width: Int(naturalSize.width),
                height: Int(naturalSize.height)
              )
            : [:]

        // MARK: Dispatch segments with bounded parallelism
        let totalSegments = ranges.count
        let stem = url.deletingPathExtension().lastPathComponent
        let concurrencyCap = max(1, config.parallelJobs)

        // Capture actor-stored exporters into plain locals before entering the
        // TaskGroup so the @Sendable sending closures below can reference them
        // without touching self's actor isolation boundary at capture time.
        let capturedPassthrough = passthroughExporter
        let capturedReencode = reencodeExporter

        // [String: Any] is not Sendable; box it once so it can cross the
        // sending boundary into the static runSegment helper.
        let settingsBox = SettingsBox(videoOutputSettings)

        // Track completion count for segmentComplete progress events. Wrapped
        // in an actor-isolated class so the @Sendable TaskGroup closures can
        // update it safely.
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
        }
        let completedCounter = Counter()

        try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var launched = 0

            // Seed the group up to the concurrency cap.
            for i in 0 ..< min(concurrencyCap, totalSegments) {
                launched += 1
                let range = ranges[i]
                let segmentIndex = i
                group.addTask { [capturedPassthrough, capturedReencode, settingsBox] in
                    let outputURL = outputDir
                        .appendingPathComponent(
                            String(format: "%@_part%03d.%@",
                                   stem, segmentIndex + 1, outputExt)
                        )
                    onEvent(.segmentStart(
                        file: filename,
                        segment: segmentIndex + 1,
                        total: totalSegments
                    ))

                    try await Self.runSegment(
                        asset: asset,
                        range: range,
                        outputURL: outputURL,
                        fileType: fileType,
                        routeIsReencode: routeIsReencode,
                        videoOutputSettings: settingsBox,
                        frameRateOverride: fpsOverrideDiffers ? effectiveFrameRate : nil,
                        preferredTransform: preferredTransform,
                        passthroughExporter: capturedPassthrough,
                        reencodeExporter: capturedReencode
                    )

                    return (segmentIndex + 1, outputURL.path)
                }
            }

            // Drain as segments finish, launching replacements until we've
            // consumed all ranges. This keeps at most `concurrencyCap`
            // exports in flight at any moment.
            while let finished = try await group.next() {
                let completed = completedCounter.increment()
                onEvent(.segmentComplete(
                    file: filename,
                    segment: finished.0,
                    total: totalSegments,
                    output: finished.1
                ))
                // Emit rolled-up file progress as we go.
                _ = completed

                if launched < totalSegments {
                    let segmentIndex = launched
                    launched += 1
                    let range = ranges[segmentIndex]
                    group.addTask { [capturedPassthrough, capturedReencode, settingsBox] in
                        let outputURL = outputDir
                            .appendingPathComponent(
                                String(format: "%@_part%03d.%@",
                                       stem, segmentIndex + 1, outputExt)
                            )
                        onEvent(.segmentStart(
                            file: filename,
                            segment: segmentIndex + 1,
                            total: totalSegments
                        ))

                        try await Self.runSegment(
                            asset: asset,
                            range: range,
                            outputURL: outputURL,
                            fileType: fileType,
                            routeIsReencode: routeIsReencode,
                            videoOutputSettings: settingsBox,
                            frameRateOverride: fpsOverrideDiffers ? effectiveFrameRate : nil,
                            preferredTransform: preferredTransform,
                            passthroughExporter: capturedPassthrough,
                            reencodeExporter: capturedReencode
                        )

                        return (segmentIndex + 1, outputURL.path)
                    }
                }
            }
        }

        // MARK: File complete
        onEvent(.fileComplete(
            file: filename,
            success: true,
            outputDir: outputDir.path,
            segmentsCompleted: totalSegments,
            segmentsTotal: totalSegments
        ))
    } // splitOne

    // MARK: - Segment dispatch

    /// Route a single segment to the correct exporter. Static to avoid
    /// capturing `self` in the TaskGroup closures.
    private static func runSegment(
        asset: AVURLAsset,
        range: CMTimeRange,
        outputURL: URL,
        fileType: AVFileType,
        routeIsReencode: Bool,
        videoOutputSettings: SettingsBox,
        frameRateOverride: Double?,
        preferredTransform: CGAffineTransform,
        passthroughExporter: SegmentPassthroughExporter,
        reencodeExporter: SegmentReencodeExporter
    ) async throws {
        if routeIsReencode {
            try await reencodeExporter.export(
                asset: asset,
                timeRange: range,
                outputURL: outputURL,
                fileType: fileType,
                videoOutputSettings: videoOutputSettings.value,
                targetFrameRate: frameRateOverride,
                preferredTransform: preferredTransform,
                includeAudio: true
            )
        } else {
            try await passthroughExporter.export(
                asset: asset,
                timeRange: range,
                outputURL: outputURL,
                fileType: fileType
            )
        }
    } // runSegment

    // MARK: - Output folder resolution

    /// Resolve and create the output directory for a given input, per the
    /// `OutputFolderMode` setting.
    ///
    /// - `.perFile`: `<parent>/<stem>_parts/`
    /// - `.alongside`: `<parent>/`
    private func resolveOutputFolder(
        for inputURL: URL,
        mode: OutputFolderMode
    ) throws -> URL {
        let parent = inputURL.deletingLastPathComponent()
        let target: URL
        switch mode {
        case .perFile:
            let stem = inputURL.deletingPathExtension().lastPathComponent
            target = parent.appendingPathComponent("\(stem)_parts", isDirectory: true)
        case .alongside:
            target = parent
        }

        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.createDirectory(
                    at: target,
                    withIntermediateDirectories: true
                )
            } catch {
                throw SplitError.outputFolderCreationFailed(
                    path: target.path, underlying: error
                )
            }
        }
        return target
    } // resolveOutputFolder

} // VideoSplitter actor

// MARK: - Validation Tests
#if DEBUG

/// Tests for VideoSplitter focusing on pre-flight rejection. End-to-end
/// splits are verified by running a real config through the app.
enum VideoSplitterTests {

    @discardableResult
    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        var passed = 0
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failures.append(name) }
        } // check

        // MARK: Error descriptions

        let errors: [VideoSplitter.SplitError] = [
            .configInvalid(reason: "x"),
            .assetHasNoVideoTrack(path: "/x.mp4"),
            .outputFolderCreationFailed(
                path: "/x", underlying: NSError(domain: "t", code: 1)
            )
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        // MARK: Async rejection of invalid config
        // NSLock is banned in async contexts under Swift 6 strict concurrency,
        // so the boolean result is funneled through an @unchecked-Sendable
        // ResultHolder with its own internal NSLock guarded by synchronous
        // setters/getters. Same pattern as GifRendererTests.
        final class ResultHolder: @unchecked Sendable {
            private let lock = NSLock()
            private var rejected = false
            func setRejected() {
                lock.lock(); defer { lock.unlock() }
                rejected = true
            }
            func wasRejected() -> Bool {
                lock.lock(); defer { lock.unlock() }
                return rejected
            }
        }
        let holder = ResultHolder()
        let sem = DispatchSemaphore(value: 0)

        Task.detached {
            let splitter = VideoSplitter()
            let empty = SplitConfig(
                inputs: [], method: .duration, splitValue: 60,
                globalFrameRate: 30, perFileFrameRate: [:], usePerFileFrameRate: false,
                codec: .h264, qualityMode: .quality, qualityValue: 50,
                outputFolderMode: .perFile, parallelJobs: 4
            )
            do {
                try await splitter.split(config: empty, onEvent: { _ in })
            } catch VideoSplitter.SplitError.configInvalid {
                holder.setRejected()
            } catch {
                // wrong error type
            }
            sem.signal()
        }
        sem.wait()
        check("empty-inputs config rejected with configInvalid", holder.wasRejected())

        print("VideoSplitterTests: \(passed) passed, \(failures.count) failed")
        for name in failures {
            print("  FAILED: \(name)")
        }
        return (passed, failures.count, failures)
    } // runAll
} // VideoSplitterTests

#endif
