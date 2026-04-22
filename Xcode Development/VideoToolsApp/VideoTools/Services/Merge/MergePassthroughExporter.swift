import Foundation
import AVFoundation

// MARK: - MergePassthroughExporter

/// Actor that exports a pre-assembled `AVMutableComposition` as a single
/// output file using `AVAssetExportPresetPassthrough`.
///
/// Replaces the Python merger's ffmpeg concat-demuxer code path. Because
/// the caller has already composed the inputs into one composition on a
/// single timeline, this exporter is a thin wrapper around
/// `AVAssetExportSession`. The passthrough preset keeps original video and
/// audio sample data intact; only the container is rewritten.
///
/// Responsibility for the compatibility check lives in
/// `MergeCompatibilityChecker`; by the time this exporter is invoked, the
/// caller has already established that the inputs share codec, dimensions,
/// and frame rate.
actor MergePassthroughExporter {

    // MARK: - Errors

    enum ExportError: Error, LocalizedError {
        case sessionCreationFailed(preset: String)
        case exportFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .sessionCreationFailed(let preset):
                return "Could not create AVAssetExportSession for preset '\(preset)'."
            case .exportFailed(let err):
                return "Passthrough merge export failed: \(err.localizedDescription)"
            }
        } // errorDescription
    } // ExportError

    // MARK: - Public API

    /// Export the composition to `outputURL`.
    ///
    /// - Parameters:
    ///   - composition: Pre-assembled composition carrying all sources
    ///                  appended sequentially from time zero.
    ///   - outputURL: Destination path. Existing files at this path are
    ///                removed before export begins.
    ///   - fileType: Output container. Inferred by the caller from the
    ///               resolved output filename extension (typically `.mp4`
    ///               or `.mov`).
    func export(
        composition: AVComposition,
        outputURL: URL,
        fileType: AVFileType
    ) async throws {

        // Remove any existing file. AVAssetExportSession refuses to overwrite.
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let presetName = AVAssetExportPresetPassthrough
        guard let session = AVAssetExportSession(
            asset: composition, presetName: presetName
        ) else {
            throw ExportError.sessionCreationFailed(preset: presetName)
        }

        // shouldOptimizeForNetworkUse moves the moov atom to the front of
        // the file. Matches the legacy `-movflags +faststart` behavior.
        session.shouldOptimizeForNetworkUse = true

        // Modern async API (macOS 15+). Throws on failure and responds to
        // Task cancellation natively.
        do {
            try await session.export(to: outputURL, as: fileType)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExportError.exportFailed(underlying: error)
        }
    } // export
} // MergePassthroughExporter

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `MergePassthroughExporter`.
enum MergePassthroughExporterTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        struct Dummy: Error {}
        let errors: [MergePassthroughExporter.ExportError] = [
            .sessionCreationFailed(preset: AVAssetExportPresetPassthrough),
            .exportFailed(underlying: Dummy())
        ]
        for (i, e) in errors.enumerated() {
            check("error \(i) has description",
                  (e.errorDescription ?? "").isEmpty == false)
        }

        print("MergePassthroughExporterTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // MergePassthroughExporterTests

#endif
