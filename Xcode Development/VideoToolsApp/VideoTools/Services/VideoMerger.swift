import Foundation
import AVFoundation
import CoreMedia

// MARK: - VideoMerger

/// Top-level orchestrator for the native video merger.
///
/// Replaces the legacy `PythonRunner.runMerger` subprocess path with a pure
/// AVFoundation pipeline. Consumes a `MergeConfig`, probes each input,
/// optionally runs a copy-mode compatibility check, builds an
/// `AVMutableComposition` via `CompositionBuilder`, and dispatches to either
/// the passthrough exporter (copy codec) or the re-encode exporter
/// (H.264 / HEVC). Emits `ProcessingEvent` values through a caller-supplied
/// closure.
///
/// ### Event shape
///
/// Unlike the splitter (which emits per-input-file lifecycle events), the
/// merger produces a single output file from N inputs. To match the legacy
/// Python merger's event contract (so `ProcessButton`'s progress-tracking
/// UI keeps working unchanged):
/// - `start(totalFiles: 1, ...)` — one "file" = the merged output
/// - `fileStart(file: "merge", ...)`
/// - `segmentStart`/`segmentComplete` per probed input while the
///   composition is being assembled (drives the per-input progress strip)
/// - `fileComplete(file: "merge", ...)` when the final output is written
/// - `complete(totalFiles: 1, ...)`
actor VideoMerger {

    // MARK: - Dependencies

    private let passthroughExporter: MergePassthroughExporter
    private let reencodeExporter: MergeReencodeExporter

    init(
        passthroughExporter: MergePassthroughExporter = MergePassthroughExporter(),
        reencodeExporter: MergeReencodeExporter = MergeReencodeExporter()
    ) {
        self.passthroughExporter = passthroughExporter
        self.reencodeExporter = reencodeExporter
    } // init

    // MARK: - Errors

    enum MergeError: Error, LocalizedError {
        case configInvalid(reason: String)
        case incompatibleForCopy(reason: String)
        case outputDirectoryCreationFailed(path: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case .configInvalid(let reason):
                return "MergeConfig is invalid: \(reason)"
            case .incompatibleForCopy(let reason):
                return reason
            case .outputDirectoryCreationFailed(let path, let err):
                return "Could not create output directory \(path): \(err.localizedDescription)"
            }
        } // errorDescription
    } // MergeError

    // MARK: - Public API

    /// Run one batch merge per the provided config.
    ///
    /// Emits `start` + `fileStart` + per-input `segmentStart/Complete`
    /// events during probe, then either passthrough or re-encode export,
    /// then `fileComplete` + `complete`. Config validation errors throw
    /// synchronously. Per-input probe failure, compatibility mismatch in
    /// copy mode, or export failure surfaces as a `fileError` on the
    /// "merge" pseudo-file and the batch ends with `complete(successful:
    /// 0, failed: 1)`.
    func merge(
        config: MergeConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        // MARK: Pre-flight
        if let err = config.validationError {
            onEvent(.error(message: err))
            throw MergeError.configInvalid(reason: err)
        }

        onEvent(.start(totalFiles: 1, hardwareAcceleration: true))
        onEvent(.progress(currentFile: 1, totalFiles: 1, filename: config.outputFilename))
        onEvent(.fileStart(file: "merge", path: config.outputURL.path))

        do {
            try await mergeOne(config: config, onEvent: onEvent)
            onEvent(.fileComplete(
                file: "merge",
                success: true,
                outputDir: config.outputDirectory.path,
                segmentsCompleted: config.inputs.count,
                segmentsTotal: config.inputs.count
            ))
            onEvent(.complete(totalFiles: 1, successful: 1, failed: 0))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onEvent(.fileError(file: "merge", error: error.localizedDescription))
            onEvent(.complete(totalFiles: 1, successful: 0, failed: 1))
        }
    } // merge

    // MARK: - Per-batch pipeline

    /// Probe, compose, export. Thrown errors are caught by `merge` and
    /// surfaced as `fileError`.
    private func mergeOne(
        config: MergeConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {

        let totalInputs = config.inputs.count

        // MARK: Probe every input
        // One segmentStart / segmentComplete pair per input drives the
        // progress strip. We carry InputVideoInfo through so the
        // compatibility check and the bitrate-anchor calculation have it
        // without a second pass.
        var probed: [InputVideoInfo] = []
        probed.reserveCapacity(totalInputs)

        for (i, url) in config.inputs.enumerated() {
            try Task.checkCancellation()
            onEvent(.segmentStart(
                file: "merge", segment: i + 1, total: totalInputs
            ))

            let info = try await probe(url: url)
            probed.append(info)

            onEvent(.segmentComplete(
                file: "merge",
                segment: i + 1,
                total: totalInputs,
                output: url.path
            ))
        }

        // MARK: Compatibility check for copy mode
        if config.codec == .copy {
            if let reason = MergeCompatibilityChecker.copyModeError(inputs: probed) {
                throw MergeError.incompatibleForCopy(reason: reason)
            }
        }

        // MARK: Ensure output directory exists
        try ensureDirectoryExists(config.outputDirectory)

        // MARK: Build composition
        let isReencode = (config.codec != .copy)
        let composition = try await CompositionBuilder.build(
            inputs: config.inputs,
            aspectMode: config.aspectMode,
            targetFrameRate: config.frameRate,
            isReencode: isReencode
        )

        // MARK: Resolve container type
        let outputURL = config.outputURL
        let ext = outputURL.pathExtension
        let fileType = SegmentPassthroughExporter.fileType(forExtension: ext) ?? .mp4

        // MARK: Dispatch
        if isReencode, let videoComposition = composition.videoComposition {
            // Anchor the H.264 quality slider to the max estimated bitrate
            // across inputs, since there's no single "source bitrate" for a
            // multi-source merge. HEVC constant-quality ignores this value.
            let maxBitrate = probed.map(\.estimatedDataRate).max() ?? 5_000_000
            let settings = SplitEncoderSettings.videoOutputSettings(
                codec: config.codec,
                qualityMode: config.qualityMode,
                qualitySlider: config.qualityValue,
                sourceBitrate: maxBitrate,
                width: Int(composition.targetSize.width),
                height: Int(composition.targetSize.height)
            )

            // Load tracks here (on this actor's isolation) so the exporter
            // does not need to send composition across actor boundaries,
            // satisfying Swift 6 strict concurrency.
            let reencodeComp = composition.composition
            let videoTracks = try await reencodeComp.loadTracks(withMediaType: .video)
            let audioTracks = try await reencodeComp.loadTracks(withMediaType: .audio)

            try await reencodeExporter.export(
                composition: reencodeComp,
                videoTracks: videoTracks,
                audioTracks: audioTracks,
                videoComposition: videoComposition,
                outputURL: outputURL,
                fileType: fileType,
                videoOutputSettings: settings
            )
        } else {
            try await passthroughExporter.export(
                composition: composition.composition,
                outputURL: outputURL,
                fileType: fileType
            )
        }
    } // mergeOne

    // MARK: - Probe

    /// Probe a single input via AVFoundation. Populates the fields
    /// `MergeCompatibilityChecker` and the orchestrator need downstream.
    private func probe(url: URL) async throws -> InputVideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            throw CompositionBuilder.BuildError.noVideoTrack(path: url.path)
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let nominalFPS = try await videoTrack.load(.nominalFrameRate)
        let estimatedBitrate = Int(try await videoTrack.load(.estimatedDataRate))
        let formatDescriptions = try await videoTrack.load(.formatDescriptions)
        let codec: UInt32 = formatDescriptions.first.map {
            CMFormatDescriptionGetMediaSubType($0)
        } ?? 0

        // Displayed size = abs(naturalSize.applying(preferredTransform)).
        let displayed = CGSize(width: naturalSize.width, height: naturalSize.height)
            .applying(preferredTransform)
        let displayWidth = Int(abs(displayed.width))
        let displayHeight = Int(abs(displayed.height))

        let hasAudio = try await asset.loadTracks(withMediaType: .audio).first != nil

        return InputVideoInfo(
            url: url,
            codecFourCC: codec,
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            nominalFrameRate: Double(nominalFPS),
            duration: duration,
            hasAudio: hasAudio,
            estimatedDataRate: estimatedBitrate
        )
    } // probe

    // MARK: - Helpers

    /// Create the output directory if it doesn't exist. Mirrors the splitter
    /// orchestrator's equivalent helper.
    private func ensureDirectoryExists(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.createDirectory(
                    at: url, withIntermediateDirectories: true
                )
            } catch {
                throw MergeError.outputDirectoryCreationFailed(
                    path: url.path, underlying: error
                )
            }
        }
    } // ensureDirectoryExists

    // Helper: apply CGAffineTransform to a CGSize (used by probe). CGSize
    // doesn't have an `.applying` instance method in older SDKs; this
    // inline bridge keeps the probe code tidy.
    // Note: CGSize.applying(_:) does exist in recent SDKs, but we redefine
    // here to ensure compile on older toolchains if ever needed.
} // VideoMerger actor

// MARK: - Validation Tests
#if DEBUG

/// Tests for VideoMerger focusing on pre-flight rejection. End-to-end
/// correctness is verified by running a real config through the UI.
enum VideoMergerTests {

    @discardableResult
    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        var passed = 0
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failures.append(name) }
        } // check

        // MARK: Error descriptions
        let errors: [VideoMerger.MergeError] = [
            .configInvalid(reason: "x"),
            .incompatibleForCopy(reason: "y"),
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
            let merger = VideoMerger()
            let invalid = MergeConfig(
                inputs: [URL(fileURLWithPath: "/tmp/a.mp4")],  // only one input
                outputFilename: "out.mp4",
                outputDirectory: URL(fileURLWithPath: "/tmp"),
                aspectMode: .letterbox,
                codec: .h264,
                qualityMode: .quality,
                qualityValue: 50,
                frameRate: 30
            )
            do {
                try await merger.merge(config: invalid, onEvent: { _ in })
            } catch VideoMerger.MergeError.configInvalid {
                holder.setRejected()
            } catch {
                // wrong error type
            }
            sem.signal()
        }
        sem.wait()
        check("single-input config rejected with configInvalid",
              holder.wasRejected())

        print("VideoMergerTests: \(passed) passed, \(failures.count) failed")
        for name in failures {
            print("  FAILED: \(name)")
        }
        return (passed, failures.count, failures)
    } // runAll
} // VideoMergerTests

#endif
