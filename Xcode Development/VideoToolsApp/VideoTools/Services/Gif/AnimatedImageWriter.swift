import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - AnimatedImageWriter

/// Writes a sequence of `CGImage` frames to an animated GIF or APNG file
/// using ImageIO's `CGImageDestination` API.
///
/// This replaces the legacy Python pipeline's use of Pillow (`PIL.Image.save`
/// with `save_all=True, append_images=[...]`) for GIF output and Pillow's
/// APNG support for APNG output. The native path eliminates the Pillow
/// dependency entirely.
///
/// ### Lifecycle
/// 1. `init(url:format:frameRate:loopCount:)` — configure the writer.
/// 2. `beginWriting()` — create the ImageIO destination and set file-level
///    properties (loop count).
/// 3. `appendFrame(_:)` — called once per frame, in output order.
/// 4. `finalize()` — flush to disk.
///
/// Uniform per-frame delay is computed from `frameRate` at init and applied
/// to every frame. Matches the Python pipeline behavior; variable per-frame
/// delay is not in scope.
///
/// ### Format support
/// GIF and APNG only. WebP encoding is not available from ImageIO on macOS
/// (including macOS 26), which is why WebP is absent from `GifOutputFormat`
/// rather than merely disabled.
///
/// ### Loop count semantics
/// The `loopCount` integer follows ImageIO's convention:
///   - 0 = infinite loop
///   - 1 = play once (no repeat)
///   - N = play N times total
/// The caller is expected to translate `GifLoopMode` + any custom count into
/// this absolute integer before constructing the writer (matching `GifRenderConfig`).
actor AnimatedImageWriter {

    // MARK: - Config

    nonisolated let outputURL: URL
    nonisolated let format: GifOutputFormat
    nonisolated let frameRate: Double
    nonisolated let loopCount: Int
    nonisolated let frameDelay: Double

    // MARK: - State

    private var destination: CGImageDestination?
    private var framesWritten: Int = 0
    private var finalized: Bool = false

    // MARK: - Errors

    enum WriterError: Error, LocalizedError {
        case invalidFrameRate(Double)
        case negativeLoopCount(Int)
        case outputDirectoryMissing(URL)
        case destinationCreateFailed(URL)
        case appendBeforeBegin
        case appendAfterFinalize
        case finalizeBeforeBegin
        case finalizeWithNoFrames
        case finalizeFlushFailed(URL)

        var errorDescription: String? {
            switch self {
            case .invalidFrameRate(let fps):
                return "Invalid frame rate \(fps); must be > 0."
            case .negativeLoopCount(let n):
                return "Invalid loop count \(n); must be >= 0 (0 = infinite)."
            case .outputDirectoryMissing(let url):
                return "Output directory does not exist: \(url.deletingLastPathComponent().path)"
            case .destinationCreateFailed(let url):
                return "Failed to create image destination at \(url.path)"
            case .appendBeforeBegin:
                return "appendFrame called before beginWriting"
            case .appendAfterFinalize:
                return "appendFrame called after finalize"
            case .finalizeBeforeBegin:
                return "finalize called before beginWriting"
            case .finalizeWithNoFrames:
                return "finalize called with zero frames written"
            case .finalizeFlushFailed(let url):
                return "CGImageDestinationFinalize returned false writing \(url.path)"
            }
        } // errorDescription
    } // WriterError

    // MARK: - Init

    /// Initialize a writer for a given output URL, format, and timing.
    ///
    /// - Parameters:
    ///   - url: Destination file URL. The containing directory must exist.
    ///   - format: `.gif` or `.apng`.
    ///   - frameRate: Output frames per second (> 0). Used to compute the uniform
    ///     per-frame delay of `1.0 / frameRate`.
    ///   - loopCount: Number of loops. 0 = infinite, 1 = play once, N = play N times.
    init(url: URL, format: GifOutputFormat, frameRate: Double, loopCount: Int) {
        self.outputURL = url
        self.format = format
        self.frameRate = frameRate
        self.loopCount = loopCount
        // Clamp delay to a sane floor; ImageIO accepts 0 but viewers behave
        // unpredictably below about 1ms. The unclamped property still means
        // viewers won't enforce the legacy 0.02s minimum.
        if frameRate > 0 {
            self.frameDelay = max(0.001, 1.0 / frameRate)
        } else {
            self.frameDelay = 0.04 // Safe default; beginWriting will reject fps <= 0.
        }
    } // init

    // MARK: - Begin

    /// Create the ImageIO destination and write file-level properties (loop count).
    /// Must be called exactly once before any `appendFrame` call.
    func beginWriting() throws {
        // Validate config up front.
        guard frameRate > 0 else { throw WriterError.invalidFrameRate(frameRate) }
        guard loopCount >= 0 else { throw WriterError.negativeLoopCount(loopCount) }

        // Ensure parent directory exists. ImageIO silently fails otherwise on some
        // sandbox configurations, which produces a very opaque error downstream.
        let parentDir = outputURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: parentDir.path, isDirectory: &isDir)
        guard exists, isDir.boolValue else {
            throw WriterError.outputDirectoryMissing(outputURL)
        }

        // Resolve UTType and expected total-frame hint. ImageIO uses the frame
        // count hint to size internal buffers; passing a rough 0 is fine if
        // unknown at begin time.
        let utType: CFString
        switch format {
        case .gif:  utType = UTType.gif.identifier as CFString
        case .apng: utType = UTType.png.identifier as CFString
        }

        guard let dest = CGImageDestinationCreateWithURL(
            outputURL as CFURL,
            utType,
            0, // frame count hint; ImageIO grows as needed
            nil
        ) else {
            throw WriterError.destinationCreateFailed(outputURL)
        }

        // Write file-level properties (loop count lives here for both GIF and APNG).
        let fileProps: CFDictionary
        switch format {
        case .gif:
            fileProps = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFLoopCount as String: loopCount
                ]
            ] as CFDictionary
        case .apng:
            fileProps = [
                kCGImagePropertyPNGDictionary as String: [
                    kCGImagePropertyAPNGLoopCount as String: loopCount
                ]
            ] as CFDictionary
        }
        CGImageDestinationSetProperties(dest, fileProps)
        self.destination = dest
    } // beginWriting

    // MARK: - Append

    /// Append a single frame to the output file with the configured uniform delay.
    ///
    /// Uses the `Unclamped` delay property (both GIF and APNG) so that
    /// framerates above 50fps are respected. The legacy `DelayTime` property
    /// is clamped by most viewers to a minimum of 0.02 seconds.
    ///
    /// - Parameter image: Pre-composed, target-sized CGImage in RGB/RGBA.
    ///   Non-RGB images are converted by ImageIO but pay a performance cost;
    ///   callers should pre-convert in the compose step for best throughput.
    func appendFrame(_ image: CGImage) throws {
        guard !finalized else { throw WriterError.appendAfterFinalize }
        guard let dest = destination else { throw WriterError.appendBeforeBegin }

        let frameProps: CFDictionary
        switch format {
        case .gif:
            frameProps = [
                kCGImagePropertyGIFDictionary as String: [
                    kCGImagePropertyGIFUnclampedDelayTime as String: frameDelay
                ]
            ] as CFDictionary
        case .apng:
            frameProps = [
                kCGImagePropertyPNGDictionary as String: [
                    kCGImagePropertyAPNGUnclampedDelayTime as String: frameDelay
                ]
            ] as CFDictionary
        }

        CGImageDestinationAddImage(dest, image, frameProps)
        framesWritten += 1
    } // appendFrame

    // MARK: - Finalize

    /// Flush the destination to disk. After this call the writer is inert;
    /// subsequent `appendFrame` calls throw `WriterError.appendAfterFinalize`.
    func finalize() throws {
        guard let dest = destination else { throw WriterError.finalizeBeforeBegin }
        guard framesWritten > 0 else { throw WriterError.finalizeWithNoFrames }

        let ok = CGImageDestinationFinalize(dest)
        finalized = true
        destination = nil // release the destination early
        if !ok {
            throw WriterError.finalizeFlushFailed(outputURL)
        }
    } // finalize

    // MARK: - Accessors for tests/diagnostics

    /// Number of frames successfully appended. Useful for diagnostics and tests.
    var frameCount: Int { framesWritten }

    /// Whether `finalize()` has been called.
    var isFinalized: Bool { finalized }

} // AnimatedImageWriter actor

// MARK: - Future Work

/*
 Native palette generation and dithering (GIF only)
 ==================================================

 This writer relies on ImageIO's internal color quantizer, which produces
 reasonable but not-tunable GIF palettes. The legacy Python pipeline
 exposed two controls that were dropped in the native port because
 ImageIO offers no API for them:
   - Colors slider (palette size, 2-256)
   - Dithering method picker (none, bayer, floyd-steinberg, sierra)

 A future agent wanting to reintroduce these controls should:

 1. Take the composed RGBA CGImage for each frame (what we currently hand
    to CGImageDestinationAddImage).

 2. Implement or link a palette quantizer. The classical approach:
    a. Collect the frame as an array of RGBA samples in a Metal buffer
       (or simple Swift array for CPU path).
    b. Run median-cut on the color cube to find the requested N
       representative colors. Vectorized SIMD or Metal compute is ideal
       for speed at larger palette sizes.
    c. For animated GIFs, either quantize each frame independently (fast,
       per-frame palettes, larger files) or compute a global palette
       across sampled frames (slower, smaller files, better frame-to-frame
       consistency).

 3. Implement dithering. Floyd-Steinberg is the sensible default; pixel-
    at-a-time error diffusion is sequential and hard to vectorize, but
    fast enough on CPU for typical GIF sizes. Bayer ordered dithering is
    trivially parallelizable on Metal.

 4. Convert the quantized 8-bit indexed image back into a CGImage with a
    kCGImagePropertyIsIndexedColor-marked colorspace, OR render indexed
    pixels back into RGBA and let ImageIO pass them through without
    re-quantizing. Both paths work; the latter is simpler but sacrifices
    a small amount of quality to the redundant ImageIO pass.

 5. Expose Colors and Dithering controls in GifSettingsView, restore the
    corresponding fields on AppState and GifRenderConfig, and wire the
    pipeline to feed pre-quantized frames to this writer when GIF format
    is selected.

 Until then: trust ImageIO, and do not claim feature parity with the
 legacy pipeline on palette control.
 */


// MARK: - Validation Tests

#if DEBUG

/// Validation tests for AnimatedImageWriter. Covers error surfaces and a
/// round-trip write+read of a real GIF and APNG file. Integration tests run
/// on a cooperative-pool Task and bridge back to the synchronous harness via
/// `DispatchSemaphore`; safe because the writer is not @MainActor.
enum AnimatedImageWriterTests {

    // MARK: Result holder (thread-safe bridge)

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

    // MARK: - Synthetic frame helper

    /// Build a 10x10 solid-color CGImage in sRGB RGBA (premultiplied).
    /// Inputs are 0-1 floats. Returns nil only on CGContext allocation failure.
    static func makeSolidFrame(red: Double, green: Double, blue: Double) -> CGImage? {
        let w = 10, h = 10
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    } // makeSolidFrame

    // MARK: - Runner

    static func runAll() -> (passed: Int, failed: Int, failures: [String]) {
        let holder = ResultHolder()

        // MARK: Sync tests: error descriptions

        let errs: [AnimatedImageWriter.WriterError] = [
            .invalidFrameRate(-1),
            .negativeLoopCount(-3),
            .outputDirectoryMissing(URL(fileURLWithPath: "/tmp/nope/file.gif")),
            .destinationCreateFailed(URL(fileURLWithPath: "/tmp/out.gif")),
            .appendBeforeBegin,
            .appendAfterFinalize,
            .finalizeBeforeBegin,
            .finalizeWithNoFrames,
            .finalizeFlushFailed(URL(fileURLWithPath: "/tmp/out.gif"))
        ]
        for (i, e) in errs.enumerated() {
            holder.check("error \(i) has description",
                         (e.errorDescription ?? "").isEmpty == false)
        }

        // MARK: Sync test: synthetic frame generation
        let frame = makeSolidFrame(red: 1, green: 0, blue: 0)
        holder.check("synthetic frame non-nil", frame != nil)
        holder.check("synthetic frame 10x10",
                     frame?.width == 10 && frame?.height == 10,
                     "got \(frame?.width ?? -1)x\(frame?.height ?? -1)")

        // MARK: Async integration tests

        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            await runAsyncTests(into: holder)
            sem.signal()
        }
        sem.wait()

        return holder.snapshot()
    } // runAll

    // MARK: - Async tests

    private static func runAsyncTests(into holder: ResultHolder) async {
        // Work in a temp subdirectory unique to this run.
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("animwriter_tests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // MARK: Rejection tests

        // fps <= 0 rejected
        do {
            let w = AnimatedImageWriter(
                url: base.appendingPathComponent("b.gif"),
                format: .gif, frameRate: 0, loopCount: 0
            )
            do {
                try await w.beginWriting()
                holder.check("fps<=0 rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.invalidFrameRate {
                holder.check("fps<=0 rejected", true)
            } catch {
                holder.check("fps<=0 rejected", false, "wrong error: \(error)")
            }
        }

        // Negative loopCount rejected
        do {
            let w = AnimatedImageWriter(
                url: base.appendingPathComponent("c.gif"),
                format: .gif, frameRate: 15, loopCount: -1
            )
            do {
                try await w.beginWriting()
                holder.check("negative loop rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.negativeLoopCount {
                holder.check("negative loop rejected", true)
            } catch {
                holder.check("negative loop rejected", false, "wrong error: \(error)")
            }
        }

        // Append before begin rejected
        do {
            let w = AnimatedImageWriter(
                url: base.appendingPathComponent("d.gif"),
                format: .gif, frameRate: 15, loopCount: 0
            )
            guard let f = makeSolidFrame(red: 1, green: 0, blue: 0) else {
                holder.check("append before begin", false, "no synthetic frame")
                return
            }
            do {
                try await w.appendFrame(f)
                holder.check("append before begin rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.appendBeforeBegin {
                holder.check("append before begin rejected", true)
            } catch {
                holder.check("append before begin rejected", false, "wrong error: \(error)")
            }
        }

        // Finalize before begin rejected
        do {
            let w = AnimatedImageWriter(
                url: base.appendingPathComponent("e.gif"),
                format: .gif, frameRate: 15, loopCount: 0
            )
            do {
                try await w.finalize()
                holder.check("finalize before begin rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.finalizeBeforeBegin {
                holder.check("finalize before begin rejected", true)
            } catch {
                holder.check("finalize before begin rejected", false, "wrong error: \(error)")
            }
        }

        // Finalize with no frames rejected
        do {
            let url = base.appendingPathComponent("f.gif")
            let w = AnimatedImageWriter(url: url, format: .gif, frameRate: 15, loopCount: 0)
            do {
                try await w.beginWriting()
                try await w.finalize()
                holder.check("finalize w/ no frames rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.finalizeWithNoFrames {
                holder.check("finalize w/ no frames rejected", true)
            } catch {
                holder.check("finalize w/ no frames rejected", false, "wrong error: \(error)")
            }
        }

        // MARK: Round-trip: GIF write + read-back

        do {
            let url = base.appendingPathComponent("roundtrip.gif")
            let w = AnimatedImageWriter(url: url, format: .gif, frameRate: 15, loopCount: 0)
            let frames = [
                makeSolidFrame(red: 1, green: 0, blue: 0),
                makeSolidFrame(red: 0, green: 1, blue: 0),
                makeSolidFrame(red: 0, green: 0, blue: 1)
            ]
            do {
                try await w.beginWriting()
                for case let frame? in frames {
                    try await w.appendFrame(frame)
                }
                try await w.finalize()
                let frameCount = await w.frameCount
                holder.check("GIF frameCount counter", frameCount == 3, "got \(frameCount)")
                holder.check("GIF file exists",
                             FileManager.default.fileExists(atPath: url.path))
                // Read back and verify via ImageIO.
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let count = CGImageSourceGetCount(src)
                    holder.check("GIF re-read frame count", count == 3, "got \(count)")
                    // Loop count should be 0 (infinite).
                    if let props = CGImageSourceCopyProperties(src, nil) as? [String: Any],
                       let gifDict = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                       let loop = gifDict[kCGImagePropertyGIFLoopCount as String] as? Int {
                        holder.check("GIF loop count infinite", loop == 0, "got \(loop)")
                    } else {
                        holder.check("GIF loop count infinite", false, "missing property")
                    }
                } else {
                    holder.check("GIF re-read frame count", false, "could not open source")
                }
            } catch {
                holder.check("GIF round-trip", false, "threw: \(error)")
            }
        }

        // MARK: Round-trip: APNG write + read-back

        do {
            let url = base.appendingPathComponent("roundtrip.png")
            let w = AnimatedImageWriter(url: url, format: .apng, frameRate: 30, loopCount: 2)
            let frames = [
                makeSolidFrame(red: 1, green: 1, blue: 0),
                makeSolidFrame(red: 0, green: 1, blue: 1)
            ]
            do {
                try await w.beginWriting()
                for case let frame? in frames {
                    try await w.appendFrame(frame)
                }
                try await w.finalize()
                holder.check("APNG file exists",
                             FileManager.default.fileExists(atPath: url.path))
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
                    let count = CGImageSourceGetCount(src)
                    holder.check("APNG re-read frame count", count == 2, "got \(count)")
                    if let props = CGImageSourceCopyProperties(src, nil) as? [String: Any],
                       let pngDict = props[kCGImagePropertyPNGDictionary as String] as? [String: Any],
                       let loop = pngDict[kCGImagePropertyAPNGLoopCount as String] as? Int {
                        holder.check("APNG loop count stored", loop == 2, "got \(loop)")
                    } else {
                        holder.check("APNG loop count stored", false, "missing property")
                    }
                } else {
                    holder.check("APNG re-read frame count", false, "could not open source")
                }
            } catch {
                holder.check("APNG round-trip", false, "threw: \(error)")
            }
        }

        // MARK: Append-after-finalize rejected

        do {
            let url = base.appendingPathComponent("after_final.gif")
            let w = AnimatedImageWriter(url: url, format: .gif, frameRate: 15, loopCount: 0)
            guard let f = makeSolidFrame(red: 0.5, green: 0.5, blue: 0.5) else {
                holder.check("append after finalize", false, "no synthetic frame")
                return
            }
            do {
                try await w.beginWriting()
                try await w.appendFrame(f)
                try await w.finalize()
                try await w.appendFrame(f)
                holder.check("append after finalize rejected", false, "no throw")
            } catch AnimatedImageWriter.WriterError.appendAfterFinalize {
                holder.check("append after finalize rejected", true)
            } catch {
                holder.check("append after finalize rejected", false, "wrong error: \(error)")
            }
        }
    } // runAsyncTests

} // AnimatedImageWriterTests

#endif
