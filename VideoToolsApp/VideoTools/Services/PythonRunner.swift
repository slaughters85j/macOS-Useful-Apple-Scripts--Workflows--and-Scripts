import Foundation

actor PythonRunner {
    private let pythonPath = "/Users/system-backup/miniforge3/bin/python"
    private let scriptsBasePath = "/Users/system-backup/Library/Mobile Documents/com~apple~ScriptEditor2/Documents/Photo & Video Management"
    
    private var currentProcess: Process?
    
    enum Script {
        case splitter
        case separator
        
        var filename: String {
            switch self {
            case .splitter: return "video_splitter_batch.py"
            case .separator: return "video_audio_separator_batch.py"
            }
        }
    }
    
    struct SplitterConfig: Encodable {
        let files: [String]
        let config: SplitterSettings
        
        struct SplitterSettings: Encodable {
            let split_method: String
            let split_value: Double
            let fps_mode: String
            let fps_value: Double
            let fps_values: [String: Double]
            let parallel_jobs: Int
        }
    }
    
    struct SeparatorConfig: Encodable {
        let files: [String]
        let config: SeparatorSettings
        
        struct SeparatorSettings: Encodable {
            let sample_rate_mode: String
            let sample_rate: Int
            let sample_rates: [String: Int]
            let parallel_jobs: Int
        }
    }
    
    func runSplitter(
        files: [String],
        splitMethod: String,
        splitValue: Double,
        fpsMode: String,
        fpsValue: Double,
        fpsValues: [String: Double],
        parallelJobs: Int,
        onEvent: @escaping @Sendable (PythonEvent) -> Void
    ) async throws {
        let config = SplitterConfig(
            files: files,
            config: .init(
                split_method: splitMethod,
                split_value: splitValue,
                fps_mode: fpsMode,
                fps_value: fpsValue,
                fps_values: fpsValues,
                parallel_jobs: parallelJobs
            )
        )
        
        try await runScript(.splitter, config: config, onEvent: onEvent)
    }
    
    func runSeparator(
        files: [String],
        sampleRateMode: String,
        sampleRate: Int,
        sampleRates: [String: Int],
        parallelJobs: Int,
        onEvent: @escaping @Sendable (PythonEvent) -> Void
    ) async throws {
        let config = SeparatorConfig(
            files: files,
            config: .init(
                sample_rate_mode: sampleRateMode,
                sample_rate: sampleRate,
                sample_rates: sampleRates,
                parallel_jobs: parallelJobs
            )
        )
        
        try await runScript(.separator, config: config, onEvent: onEvent)
    }
    
    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }
    
    private func runScript<T: Encodable>(
        _ script: Script,
        config: T,
        onEvent: @escaping @Sendable (PythonEvent) -> Void
    ) async throws {
        let scriptPath = (scriptsBasePath as NSString).appendingPathComponent(script.filename)
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]
        
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        
        currentProcess = process
        
        try process.run()
        
        let configData = try JSONEncoder().encode(config)
        inputPipe.fileHandleForWriting.write(configData)
        inputPipe.fileHandleForWriting.closeFile()
        
        let handle = outputPipe.fileHandleForReading
        
        for try await line in handle.bytes.lines {
            if let event = PythonEvent.parse(line) {
                onEvent(event)
            }
        }
        
        process.waitUntilExit()
        currentProcess = nil
        
        if process.terminationStatus != 0 {
            throw PythonRunnerError.processExitedWithError(Int(process.terminationStatus))
        }
    }
}

enum PythonRunnerError: Error, LocalizedError {
    case processExitedWithError(Int)
    
    var errorDescription: String? {
        switch self {
        case .processExitedWithError(let code):
            return "Python process exited with code \(code)"
        }
    }
}
