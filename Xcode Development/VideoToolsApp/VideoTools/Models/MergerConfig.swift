import Foundation

// MARK: - Merger Config (JSON payload sent to Python)

/// The merger still runs via the Python subprocess pipeline.
struct MergerConfig: Encodable {
    let files: [String]
    let config: Settings

    struct Settings: Encodable {
        let output_filename: String
        let aspect_mode: String
        let output_codec: String
        let quality_mode: String
        let quality_value: Double
        let fps_value: Double
        let output_dir: String
    }
}
