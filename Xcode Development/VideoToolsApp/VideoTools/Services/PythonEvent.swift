import Foundation

enum PythonEvent: Sendable {
    case start(totalFiles: Int, hardwareAcceleration: Bool)
    case progress(currentFile: Int, totalFiles: Int, filename: String)
    case fileStart(file: String, path: String)
    case fileComplete(file: String, success: Bool, outputDir: String?, segmentsCompleted: Int?, segmentsTotal: Int?)
    case fileError(file: String, error: String)
    case segmentStart(file: String, segment: Int, total: Int)
    case segmentComplete(file: String, segment: Int, total: Int, output: String)
    case complete(totalFiles: Int, successful: Int, failed: Int)
    case error(message: String)
    
    static func parse(_ jsonLine: String) -> PythonEvent? {
        guard let data = jsonLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = json["event"] as? String else {
            return nil
        }
        
        switch eventType {
        case "start":
            return .start(
                totalFiles: json["total_files"] as? Int ?? 0,
                hardwareAcceleration: json["hardware_acceleration"] as? Bool ?? false
            )
            
        case "progress":
            return .progress(
                currentFile: json["current_file"] as? Int ?? 0,
                totalFiles: json["total_files"] as? Int ?? 0,
                filename: json["filename"] as? String ?? ""
            )
            
        case "file_start":
            return .fileStart(
                file: json["file"] as? String ?? "",
                path: json["path"] as? String ?? ""
            )
            
        case "file_complete":
            return .fileComplete(
                file: json["file"] as? String ?? "",
                success: json["success"] as? Bool ?? false,
                outputDir: json["output_dir"] as? String,
                segmentsCompleted: json["segments_completed"] as? Int,
                segmentsTotal: json["segments_total"] as? Int
            )
            
        case "file_error":
            return .fileError(
                file: json["file"] as? String ?? "",
                error: json["error"] as? String ?? "Unknown error"
            )
            
        case "segment_start":
            return .segmentStart(
                file: json["file"] as? String ?? "",
                segment: json["segment"] as? Int ?? 0,
                total: json["total"] as? Int ?? 0
            )
            
        case "segment_complete":
            return .segmentComplete(
                file: json["file"] as? String ?? "",
                segment: json["segment"] as? Int ?? 0,
                total: json["total"] as? Int ?? 0,
                output: json["output"] as? String ?? ""
            )
            
        case "complete":
            return .complete(
                totalFiles: json["total_files"] as? Int ?? 0,
                successful: json["successful"] as? Int ?? 0,
                failed: json["failed"] as? Int ?? 0
            )
            
        case "error":
            return .error(message: json["message"] as? String ?? "Unknown error")
            
        default:
            return nil
        }
    }
}
