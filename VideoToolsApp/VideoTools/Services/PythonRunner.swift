import Foundation

actor PythonRunner {
    
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
        let pythonPath = try findPython()
        let scriptPath = try findScript(script)
        
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
    
    private func findPython() throws -> String {
        // Check user preference first
        if let userPath = UserDefaults.standard.string(forKey: "pythonPath"),
           FileManager.default.isExecutableFile(atPath: userPath) {
            return userPath
        }
        
        // Common Python locations
        let candidates = [
            // Miniforge/Conda
            NSHomeDirectory() + "/miniforge3/bin/python",
            NSHomeDirectory() + "/miniconda3/bin/python",
            NSHomeDirectory() + "/anaconda3/bin/python",
            "/opt/homebrew/anaconda3/bin/python",
            "/opt/anaconda3/bin/python",
            // Homebrew
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            // System
            "/usr/bin/python3"
        ]
        
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
        // Try using 'which' as fallback
        let whichProcess = Process()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["python3"]
        let pipe = Pipe()
        whichProcess.standardOutput = pipe
        
        try? whichProcess.run()
        whichProcess.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty,
           FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        
        throw PythonRunnerError.pythonNotFound
    }
    
    private func findScript(_ script: Script) throws -> String {
        // Check user preference first
        if let userPath = UserDefaults.standard.string(forKey: "scriptsPath") {
            let scriptPath = (userPath as NSString).appendingPathComponent(script.filename)
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        
        // Check in app bundle Resources
        if let bundlePath = Bundle.main.path(forResource: script.filename.replacingOccurrences(of: ".py", with: ""), ofType: "py") {
            return bundlePath
        }
        
        // Check common locations
        let candidates = [
            // iCloud Scripts folder
            NSHomeDirectory() + "/Library/Mobile Documents/com~apple~ScriptEditor2/Documents/Photo & Video Management",
            // Same directory as app
            Bundle.main.bundlePath + "/../Scripts",
            // User's home scripts
            NSHomeDirectory() + "/Scripts/VideoTools"
        ]
        
        for basePath in candidates {
            let scriptPath = (basePath as NSString).appendingPathComponent(script.filename)
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        
        throw PythonRunnerError.scriptNotFound(script.filename)
    }
}

enum PythonRunnerError: Error, LocalizedError {
    case processExitedWithError(Int)
    case pythonNotFound
    case scriptNotFound(String)
    
    var errorDescription: String? {
        switch self {
        case .processExitedWithError(let code):
            return "Python process exited with code \(code)"
        case .pythonNotFound:
            return "Python not found. Install Python 3 or set the path in Settings."
        case .scriptNotFound(let name):
            return "Script '\(name)' not found. Ensure scripts are in the app bundle or set the path in Settings."
        }
    }
}
