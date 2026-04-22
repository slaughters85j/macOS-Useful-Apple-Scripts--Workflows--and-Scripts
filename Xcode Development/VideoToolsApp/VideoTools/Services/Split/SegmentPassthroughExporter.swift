import Foundation
import AVFoundation

// MARK: - SegmentPassthroughExporter

/// Actor that exports one time-range of a source asset as a standalone output
/// file using `AVAssetExportPresetPassthrough`.
///
/// Replaces the Python splitter's `-c copy` code path. Passthrough keeps the
/// original video and audio sample data intact; only the container is
/// rewritten. AVAssetExportSession enforces keyframe-alignment on the
/// video segment boundaries, which matches ffmpeg `-c copy` behavior where
/// the start of each segment must land on a keyframe. Users may observe
/// segment durations that differ from the requested value by up to one
/// GOP length, which is identical to the legacy behavior.
///
/// Task cancellation: if the parent Task is cancelled while an export is in
/// flight, the session is cancelled and the call throws `CancellationError`.
///
/// Services that touch mutable AVFoundation state are actors by convention in
/// this project even when, as here, the type holds no mutable properties.
actor SegmentPassthroughExporter {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case sessionCreationFailed(preset: String)
        case exportFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let preset):
                return "Could not create AVAssetExportSession for preset '\(preset)'."
            case .exportFailed(let err):
                return "Passthrough export failed: \(err.localizedDescription)"
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Export one segment by performing a passthrough copy of a time range
    /// from the supplied asset into `outputURL`.
    ///
    /// - Parameters:
    ///   - asset: The source asset. Callers may reuse one `AVAsset` across
    ///            multiple segment exports to save on metadata re-parsing.
    ///   - timeRange: The source-timeline range to copy. The session's
    ///                `timeRange` property accepts this directly.
    ///   - outputURL: Destination file URL. The file is removed before the
    ///                export begins if it already exists, because
    ///                AVAssetExportSession refuses to overwrite.
    ///   - fileType: Container type for the output. Typically `.mp4` or
    ///              `.mov`, chosen by the caller to match the source
    ///              extension.
    /// - Throws: `ExportError` on any failure path, `CancellationError` if
    ///           the parent Task was cancelled.
    func export(
        asset: AVAsset,
        timeRange: CMTimeRange,
        outputURL: URL,
        fileType: AVFileType
    ) async throws {

        // Remove any existing file. AVAssetExportSession treats an existing
        // output path as a failure condition, not an overwrite, so we have
        // to do this ourselves.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // Build the session. Passthrough is the simplest preset and matches
        // the user's "copy codec" selection.
        let presetName = AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(asset: asset, presetName: presetName) else {
            throw ExportError.sessionCreationFailed(preset: presetName)
        }

        session.timeRange = timeRange
        // shouldOptimizeForNetworkUse moves the moov atom to the front of
        // the file. Cheap and usually desirable; matches Python's default
        // behavior via `-movflags +faststart` on ffmpeg.
        session.shouldOptimizeForNetworkUse = true

        // Use the modern async API (macOS 15+). It throws on failure and
        // responds to Task cancellation natively, so we don't need a
        // withTaskCancellationHandler / continuation bridge here.
        do {
            try await session.export(to: outputURL, as: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }
    } // export

    // MARK: - Helpers

    /// Map a filename extension (without the dot) to an `AVFileType` suitable
    /// for `outputFileType` on an export session.
    ///
    /// Returns `nil` for extensions this helper doesn't recognize; callers
    /// should fall back to `.mp4` in that case. Used by `VideoSplitter` to
    /// pick an output container that matches the source file.
    nonisolated static func fileType(forExtension ext: String) -> AVFileType? {
        switch ext.lowercased() {
        case "mp4", "m4v":  return .mp4
        case "mov":         return .mov
        case "m4a":         return .m4a
        default:            return nil
        }
    } // fileType(forExtension:)
} // SegmentPassthroughExporter

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SegmentPassthroughExporter`.
/// Verifies error-description plumbing and the pure `fileType(forExtension:)`
/// helper. End-to-end passthrough exports are verified by running the real
/// splitter against a test clip.
enum SegmentPassthroughExporterTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        // MARK: Error descriptions
        struct Dummy: Error {}
        let errors: [SegmentPassthroughExporter.ExportError] = [
            .sessionCreationFailed(preset: AVAssetExportPresetPassthrough),
            .exportFailed(underlying: Dummy())
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        // MARK: fileType mapping
        check("mp4 -> .mp4",
              SegmentPassthroughExporter.fileType(forExtension: "mp4") == .mp4)
        check("MP4 uppercase -> .mp4",
              SegmentPassthroughExporter.fileType(forExtension: "MP4") == .mp4)
        check("mov -> .mov",
              SegmentPassthroughExporter.fileType(forExtension: "mov") == .mov)
        check("m4v -> .mp4",
              SegmentPassthroughExporter.fileType(forExtension: "m4v") == .mp4)
        check("m4a -> .m4a",
              SegmentPassthroughExporter.fileType(forExtension: "m4a") == .m4a)
        check("unknown extension returns nil",
              SegmentPassthroughExporter.fileType(forExtension: "xyz") == nil)
        check("empty extension returns nil",
              SegmentPassthroughExporter.fileType(forExtension: "") == nil)

        print("SegmentPassthroughExporterTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SegmentPassthroughExporterTests

#endif
