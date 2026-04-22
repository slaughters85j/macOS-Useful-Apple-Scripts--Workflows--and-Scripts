import Foundation
import AVFoundation

// MARK: - VideoStreamExtractor

/// Actor that produces a video-only copy of a source file by building an
/// `AVMutableComposition` that includes only the source's video track(s) and
/// exporting with `AVAssetExportPresetPassthrough`.
///
/// Replaces the Python separator's `-an` (no audio) code path. Native
/// passthrough is strictly better than the Python path, which re-encoded
/// via H.264 VideoToolbox: no generation loss, no forced codec change, and
/// output container preserves the source extension. A `.mov` input stays
/// `.mov`, an `.mp4` stays `.mp4`.
actor VideoStreamExtractor {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case noVideoTrack(path: String)
        case compositionTrackCreationFailed
        case sessionCreationFailed(preset: String)
        case exportFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack(let path):
                return "No video track in '\(path)' to extract."
            case .compositionTrackCreationFailed:
                return "Could not create a video composition track."
            case .sessionCreationFailed(let preset):
                return "Could not create AVAssetExportSession for preset '\(preset)'."
            case .exportFailed(let err):
                return "Video extraction failed: \(err.localizedDescription)"
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Extract the video track from `sourceURL` into `outputURL` with no
    /// audio, preserving the original video stream bit-for-bit via
    /// passthrough.
    ///
    /// - Parameters:
    ///   - sourceURL: Input video file.
    ///   - outputURL: Destination. Any existing file at this path is
    ///                removed first.
    ///   - fileType: Output container type. Callers pick this from the
    ///               source file's extension so `.mov` stays `.mov`.
    func extract(
        sourceURL: URL,
        outputURL: URL,
        fileType: AVFileType
    ) async throws {

        // Remove any existing file. AVAssetExportSession refuses to
        // overwrite.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        // MARK: Build video-only composition
        let asset = AVURLAsset(url: sourceURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideoTrack = videoTracks.first else {
            throw ExportError.noVideoTrack(path: sourceURL.path)
        }
        let duration = try await asset.load(.duration)
        let preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.compositionTrackCreationFailed
        }

        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: sourceVideoTrack,
            at: .zero
        )
        // Preserve rotation / orientation by copying the source's
        // preferredTransform onto the composition track. Without this,
        // portrait-rotated sources would play upside-down or sideways in
        // the video-only output.
        videoTrack.preferredTransform = preferredTransform

        // MARK: Export
        let presetName = AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(
            asset: composition, presetName: presetName
        ) else {
            throw ExportError.sessionCreationFailed(preset: presetName)
        }
        session.shouldOptimizeForNetworkUse = true

        do {
            try await session.export(to: outputURL, as: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }
    } // extract
} // VideoStreamExtractor

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `VideoStreamExtractor`.
/// End-to-end extraction correctness is verified through the UI.
enum VideoStreamExtractorTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        struct Dummy: Error {}
        let errors: [VideoStreamExtractor.ExportError] = [
            .noVideoTrack(path: "/x.mp4"),
            .compositionTrackCreationFailed,
            .sessionCreationFailed(preset: AVAssetExportPresetPassthrough),
            .exportFailed(underlying: Dummy())
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        print("VideoStreamExtractorTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // VideoStreamExtractorTests

#endif
