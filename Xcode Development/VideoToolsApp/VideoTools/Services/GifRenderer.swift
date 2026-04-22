import Foundation
import CoreGraphics
import CoreText

// MARK: - GifRenderer

/// Top-level orchestrator for native GIF and APNG rendering.
///
/// Replaces the legacy `PythonRunner.runGifConverter` IPC path with a pure
/// AVFoundation plus ImageIO pipeline. Consumes a `GifRenderConfig`, probes
/// each source, computes kept ranges and output dimensions, extracts frames,
/// composes them into a target-sized canvas (including optional text
/// overlay), and writes them out via `AnimatedImageWriter`.
///
/// Emits `ProcessingEvent` values through a caller-supplied closure, matching
/// the existing `ProcessButton` consumer contract so the UI wiring in step 11
/// is a minimal change. "Segment" events are emitted as 1-of-1 per file since
/// the native path has no segmented encode; this preserves UI progress-bar
/// behavior until that contract is revisited.
///
/// ### Concurrency
/// Files are processed serially within one call. Task cancellation propagates
/// through `try await` at every await point. On per-file failure, the error
/// is surfaced as a `fileError` event and the batch continues with the next
/// input (matches a conservative user expectation of seeing all failures
/// rather than aborting on the first).
actor GifRenderer {

    // MARK: - Dependencies

    private let extractor: VideoFrameExtractor

    init(extractor: VideoFrameExtractor = VideoFrameExtractor()) {
        self.extractor = extractor
    } // init

    // MARK: - Errors

    enum RenderError: Error, LocalizedError {
        case emptyInputs
        case invalidTrimBounds(trimStart: Double, trimEnd: Double, duration: Double)
        case noKeepRangesAfterTrimAndCuts
        case frameContextCreationFailed(width: Int, height: Int)
        case composeImageFailed(frameIndex: Int)

        var errorDescription: String? {
            switch self {
            case .emptyInputs:
                return "GifRenderConfig has no input files."
            case .invalidTrimBounds(let s, let e, let d):
                return "Trim bounds invalid (start=\(s), end=\(e), duration=\(d))."
            case .noKeepRangesAfterTrimAndCuts:
                return "Trim and cut configuration leaves no content to render."
            case .frameContextCreationFailed(let w, let h):
                return "Could not allocate render context at \(w) x \(h)."
            case .composeImageFailed(let i):
                return "Failed to compose output image for frame \(i)."
            }
        } // errorDescription
    } // RenderError

    // MARK: - Public API

    /// Render a batch of inputs per the provided config.
    ///
    /// Emits `start` once, then per-file progress + lifecycle events, then a
    /// single `complete` event at the end. Catastrophic failures (empty
    /// inputs, disallowed format) throw synchronously; per-file failures are
    /// reported via `fileError` events and do not abort the batch.
    func render(
        config: GifRenderConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        // MARK: Pre-flight
        guard !config.inputs.isEmpty else {
            onEvent(.error(message: RenderError.emptyInputs.errorDescription ?? ""))
            throw RenderError.emptyInputs
        }

        let totalFiles = config.inputs.count
        onEvent(.start(totalFiles: totalFiles, hardwareAcceleration: false))

        var successful = 0
        var failed = 0

        for (i, url) in config.inputs.enumerated() {
            // Honor cancellation between files.
            try Task.checkCancellation()

            let filename = url.lastPathComponent
            onEvent(.progress(currentFile: i + 1, totalFiles: totalFiles, filename: filename))
            onEvent(.fileStart(file: filename, path: url.path))

            do {
                try await renderOne(url: url, config: config, onEvent: onEvent)
                successful += 1
            } catch is CancellationError {
                // Cancellation surfaces to the caller; don't count as a file failure.
                throw CancellationError()
            } catch {
                onEvent(.fileError(file: filename, error: error.localizedDescription))
                failed += 1
            }
        }

        onEvent(.complete(totalFiles: totalFiles, successful: successful, failed: failed))
    } // render

    // MARK: - Per-file Pipeline

    /// Execute the full extract-compose-write pipeline for one input file.
    private func renderOne(
        url: URL,
        config: GifRenderConfig,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        // MARK: Probe
        let (duration, srcWidth, srcHeight) = try await extractor.probe(url: url)

        // MARK: Resolve trim bounds and keep ranges
        let effectiveTrimEnd = config.trimEnd ?? duration
        guard config.trimStart >= 0,
              effectiveTrimEnd > config.trimStart,
              effectiveTrimEnd <= duration + 1e-6 else {
            throw RenderError.invalidTrimBounds(
                trimStart: config.trimStart,
                trimEnd: effectiveTrimEnd,
                duration: duration
            )
        }

        let keepRanges = KeepSegmentCalculator.keepRanges(
            duration: duration,
            trimStart: config.trimStart,
            trimEnd: effectiveTrimEnd,
            cuts: config.cutSegments,
            targetFPS: config.frameRate
        )
        guard !keepRanges.isEmpty else {
            throw RenderError.noKeepRangesAfterTrimAndCuts
        }

        // MARK: Output dimensions
        let (outWidth, outHeight) = ResolutionCalculator.outputDimensions(
            spec: config.resolution,
            sourceWidth: srcWidth,
            sourceHeight: srcHeight
        )

        // MARK: Output URL
        // Same directory as input, same stem, format's extension.
        let outputURL = url
            .deletingPathExtension()
            .appendingPathExtension(config.outputFormat.fileExtension)
        let filename = url.lastPathComponent

        // MARK: Remap overlay timing
        // Source-timeline overlay times are remapped to output timeline so
        // the overlay appears during the correct output frames after trim +
        // cuts + speed. Returns nil if the overlay window falls entirely
        // within dropped regions.
        let remappedOverlay: TextOverlay? = remapOverlayIfPresent(
            overlay: config.textOverlay,
            keepRanges: keepRanges,
            speedMultiplier: config.speedMultiplier
        )

        // MARK: Writer setup
        let writer = AnimatedImageWriter(
            url: outputURL,
            format: config.outputFormat,
            frameRate: config.frameRate,
            loopCount: config.loopCount
        )
        try await writer.beginWriting()

        onEvent(.segmentStart(file: filename, segment: 1, total: 1))

        // MARK: Extract + compose + append
        // The extractor invokes our callback once per decoded frame in
        // output-index order. For each frame we build a target-sized context,
        // draw the decoded CGImage (non-uniform scale matches Python's
        // ffmpeg `scale=W:H` behavior), apply the overlay if active, and
        // hand the composed image to the writer.
        do {
            try await extractor.extractFrames(
                url: url,
                keepRanges: keepRanges,
                frameRate: config.frameRate,
                speedMultiplier: config.speedMultiplier,
                targetWidth: outWidth,
                targetHeight: outHeight,
                onFrame: { [weak self] frame in
                    guard let self else { return }
                    try await self.composeAndAppend(
                        frame: frame,
                        outWidth: outWidth,
                        outHeight: outHeight,
                        overlay: remappedOverlay,
                        writer: writer
                    )
                }
            )
        } catch {
            // Still try to finalize anything we wrote so we don't leak a
            // partial destination. Swallow finalize errors; primary error
            // wins.
            try? await writer.finalize()
            throw error
        }

        try await writer.finalize()

        onEvent(.segmentComplete(
            file: filename, segment: 1, total: 1, output: outputURL.path
        ))
        onEvent(.fileComplete(
            file: filename,
            success: true,
            outputDir: outputURL.deletingLastPathComponent().path,
            segmentsCompleted: 1,
            segmentsTotal: 1
        ))
    } // renderOne

    // MARK: - Compose

    /// Compose a single decoded frame into the target-sized canvas, apply the
    /// overlay if active, and append to the writer.
    ///
    /// Called from the extractor's `onFrame` callback. Stays on the actor via
    /// the `self` capture, so mutable state in `writer` is accessed through
    /// actor isolation.
    private func composeAndAppend(
        frame: VideoFrameExtractor.ExtractedFrame,
        outWidth: Int,
        outHeight: Int,
        overlay: TextOverlay?,
        writer: AnimatedImageWriter
    ) async throws {
        guard let context = makeRenderContext(width: outWidth, height: outHeight) else {
            throw RenderError.frameContextCreationFailed(width: outWidth, height: outHeight)
        }

        // Fill the canvas in case the decoded frame does not cover it (e.g.
        // aspect-preserving letterbox when the decoded size is smaller than
        // the target along one axis). Black is the conventional GIF letterbox.
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        // Draw with non-uniform scale if needed. CG's rect-based draw performs
        // bilinear scaling by default; high interpolation is requested for
        // quality.
        context.interpolationQuality = .high
        context.draw(
            frame.image,
            in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight)
        )

        // Overlay is active when the frame's output time falls inside the
        // remapped overlay's [startTime, endTime] window.
        if let overlay,
           frame.outputTime >= overlay.startTime,
           frame.outputTime <= overlay.endTime {
            TextOverlayRenderer.draw(
                overlay: overlay,
                in: context,
                canvasWidth: outWidth,
                canvasHeight: outHeight
            )
        }

        guard let composed = context.makeImage() else {
            throw RenderError.composeImageFailed(frameIndex: frame.index)
        }

        try await writer.appendFrame(composed)
    } // composeAndAppend

    // MARK: - Helpers

    /// Build a render context at the given target dimensions, sRGB RGBA
    /// premultiplied. Matches the pixel format AnimatedImageWriter and
    /// TextOverlayRenderer expect.
    fileprivate nonisolated func makeRenderContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        )
    } // makeRenderContext

    /// Remap a source-timeline text overlay into the final output timeline.
    ///
    /// `KeepSegmentCalculator.mapToOutputTimeline` produces concat-timeline
    /// positions (before speed multiplier is applied). The extractor emits
    /// `frame.outputTime` values on the POST-speed timeline, so we divide by
    /// `speedMultiplier` to get matching times.
    ///
    /// Returns nil if the overlay window falls entirely inside dropped regions
    /// or if there is no overlay at all.
    fileprivate nonisolated func remapOverlayIfPresent(
        overlay: TextOverlay?,
        keepRanges: [TimeRange],
        speedMultiplier: Double
    ) -> TextOverlay? {
        guard let overlay else { return nil }
        guard speedMultiplier > 0 else { return nil }

        guard let concatRange = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: overlay.startTime,
            sourceEnd: overlay.endTime,
            keepRanges: keepRanges
        ) else {
            return nil
        }

        var remapped = overlay
        remapped.startTime = concatRange.start / speedMultiplier
        remapped.endTime = concatRange.end / speedMultiplier
        return remapped
    } // remapOverlayIfPresent

} // GifRenderer actor


// MARK: - Validation Tests

#if DEBUG

/// Tests for GifRenderer focusing on pure-logic helpers and pre-flight
/// rejection paths. End-to-end rendering is verified by running a real
/// config and comparing output against the legacy Python pipeline.
enum GifRendererTests {

    private final class ResultHolder: @unchecked Sendable {
        private let lock = NSLock()
        private var passed = 0
        private var failures: [String] = []
        func check(_ name: String, _ pass: Bool, _ detail: String = "") {
            lock.lock(); defer { lock.unlock() }
            if pass { passed += 1 }
            else { failures.append(detail.isEmpty ? name : "\(name): \(detail)") }
        }
        func snapshot() -> (passed: Int, failed: Int, failures: [String]) {
            lock.lock(); defer { lock.unlock() }
            return (passed, failures.count, failures)
        }
    } // ResultHolder

    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        let holder = ResultHolder()
        let renderer = GifRenderer()

        // MARK: Error descriptions
        let errs: [GifRenderer.RenderError] = [
            .emptyInputs,
            .invalidTrimBounds(trimStart: 5, trimEnd: 3, duration: 10),
            .noKeepRangesAfterTrimAndCuts,
            .frameContextCreationFailed(width: 0, height: 0),
            .composeImageFailed(frameIndex: 7)
        ]
        for (i, e) in errs.enumerated() {
            holder.check("error \(i) has description",
                         (e.errorDescription ?? "").isEmpty == false)
        }

        // MARK: makeRenderContext
        holder.check("context 640x480 ok",
                     renderer.makeRenderContext(width: 640, height: 480) != nil)
        holder.check("context 2x2 ok",
                     renderer.makeRenderContext(width: 2, height: 2) != nil)

        // MARK: Overlay remapping

        // Build a minimal overlay spanning source time [2, 4].
        let baseOverlay = TextOverlay(
            text: "x", startTime: 2, endTime: 4
        )

        // Case: nil overlay returns nil
        holder.check("remap: nil overlay",
                     renderer.remapOverlayIfPresent(
                        overlay: nil,
                        keepRanges: [TimeRange(start: 0, end: 10)],
                        speedMultiplier: 1) == nil)

        // Case: speed 0 is rejected (guards against divide-by-zero)
        holder.check("remap: zero speed returns nil",
                     renderer.remapOverlayIfPresent(
                        overlay: baseOverlay,
                        keepRanges: [TimeRange(start: 0, end: 10)],
                        speedMultiplier: 0) == nil)

        // Case: single keep range, speed 1. Overlay [2, 4] → output [2, 4].
        let r1 = renderer.remapOverlayIfPresent(
            overlay: baseOverlay,
            keepRanges: [TimeRange(start: 0, end: 10)],
            speedMultiplier: 1
        )
        holder.check("remap: single range speed 1 non-nil", r1 != nil)
        holder.check("remap: single range speed 1 start",
                     abs((r1?.startTime ?? -1) - 2.0) < 1e-9,
                     "got \(r1?.startTime ?? -1)")
        holder.check("remap: single range speed 1 end",
                     abs((r1?.endTime ?? -1) - 4.0) < 1e-9,
                     "got \(r1?.endTime ?? -1)")

        // Case: single keep range, speed 2. Overlay [2, 4] → concat [2,4] → output [1, 2].
        let r2 = renderer.remapOverlayIfPresent(
            overlay: baseOverlay,
            keepRanges: [TimeRange(start: 0, end: 10)],
            speedMultiplier: 2
        )
        holder.check("remap: speed 2 start",
                     abs((r2?.startTime ?? -1) - 1.0) < 1e-9,
                     "got \(r2?.startTime ?? -1)")
        holder.check("remap: speed 2 end",
                     abs((r2?.endTime ?? -1) - 2.0) < 1e-9,
                     "got \(r2?.endTime ?? -1)")

        // Case: overlay falls entirely in cut region.
        // keep ranges [0,1] and [5,6], overlay [2,4] is entirely between them.
        let r3 = renderer.remapOverlayIfPresent(
            overlay: baseOverlay,
            keepRanges: [TimeRange(start: 0, end: 1), TimeRange(start: 5, end: 6)],
            speedMultiplier: 1
        )
        holder.check("remap: overlay fully in cut -> nil", r3 == nil)

        // MARK: Async rejection paths

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await runAsyncRejectionTests(renderer: renderer, holder: holder)
            sem.signal()
        }
        sem.wait()

        return holder.snapshot()
    } // runAll

    // MARK: - Async rejection tests

    private static func runAsyncRejectionTests(
        renderer: GifRenderer,
        holder: ResultHolder
    ) async {
        // Empty inputs
        let emptyConfig = GifRenderConfig(
            inputs: [],
            outputFormat: .gif,
            resolution: .original,
            frameRate: 15,
            speedMultiplier: 1,
            loopCount: 0,
            trimStart: 0,
            trimEnd: nil,
            cutSegments: [],
            textOverlay: nil
        )
        do {
            try await renderer.render(config: emptyConfig, onEvent: { _ in })
            holder.check("render rejects empty inputs", false, "no throw")
        } catch GifRenderer.RenderError.emptyInputs {
            holder.check("render rejects empty inputs", true)
        } catch {
            holder.check("render rejects empty inputs", false, "wrong: \(error)")
        }
    } // runAsyncRejectionTests

} // GifRendererTests

#endif
