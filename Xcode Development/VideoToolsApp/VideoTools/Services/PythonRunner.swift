import Foundation

actor PythonRunner {
    
    private var currentProcess: Process?
    
    enum Script {
        case separator

        var filename: String {
            switch self {
            // Splitter (video_splitter_batch.py) and merger (video_merger.py)
            // were removed when their pipelines went native. Only the
            // Separate A/V mode still uses Python.
            case .separator: return "video_audio_separator_batch.py"
            }
        }
    }

    struct SeparatorConfig: Encodable {
        let files: [String]
        let config: SeparatorSettings

        struct SeparatorSettings: Encodable {
            let sample_rate_mode: String
            let sample_rate: Int
            let sample_rates: [String: Int]
            let audio_channels: Int
            let parallel_jobs: Int
        }
    }
    
    // `runSplitter` and its `SplitterConfig` were removed when the splitter
    // went native. See `VideoSplitter` and `Models/SplitConfig.swift`.

    func runSeparator(
        files: [String],
        sampleRateMode: String,
        sampleRate: Int,
        sampleRates: [String: Int],
        audioChannels: Int,
        parallelJobs: Int,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        let config = SeparatorConfig(
            files: files,
            config: .init(
                sample_rate_mode: sampleRateMode,
                sample_rate: sampleRate,
                sample_rates: sampleRates,
                audio_channels: audioChannels,
                parallel_jobs: parallelJobs
            )
        )
        
        try await runScript(.separator, config: config, onEvent: onEvent)
    }
    
    // `runMerger` and the top-level `MergerConfig` type were removed when
    // the merger went native. See `VideoMerger` and `Models/MergeConfig.swift`.

    func cancel() {
        currentProcess?.terminate()
        currentProcess = nil
    }
    
    private func runScript<T: Encodable>(
        _ script: Script,
        config: T,
        onEvent: @escaping @Sendable (ProcessingEvent) -> Void
    ) async throws {
        let pythonPath = try findPython()
        let scriptPath = try findScript(script)

        print("PythonRunner: Using Python at: \(pythonPath)")
        print("PythonRunner: Running script at: \(scriptPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [scriptPath]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()

        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        currentProcess = process

        try process.run()
        print("PythonRunner: Process started")

        let configData = try JSONEncoder().encode(config)
        print("PythonRunner: Sending config (\(configData.count) bytes)")
        inputPipe.fileHandleForWriting.write(configData)
        inputPipe.fileHandleForWriting.closeFile()

        let handle = outputPipe.fileHandleForReading

        for try await line in handle.bytes.lines {
            print("PythonRunner: Received line: \(line.prefix(100))")
            if let event = ProcessingEvent.parse(line) {
                onEvent(event)
            }
        }

        process.waitUntilExit()
        currentProcess = nil

        print("PythonRunner: Process exited with status \(process.terminationStatus)")

        // Read stderr for debugging
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        if !errorData.isEmpty, let errorString = String(data: errorData, encoding: .utf8) {
            print("PythonRunner stderr: \(errorString)")
        }

        if process.terminationStatus != 0 {
            throw PythonRunnerError.processExitedWithError(Int(process.terminationStatus))
        }
    }
    
    private func findPython() throws -> String {
        if let userPath = UserDefaults.standard.string(forKey: "pythonPath"),
           FileManager.default.isExecutableFile(atPath: userPath) {
            return userPath
        }
        
        let candidates = [
            NSHomeDirectory() + "/miniforge3/bin/python",
            NSHomeDirectory() + "/miniconda3/bin/python",
            NSHomeDirectory() + "/anaconda3/bin/python",
            "/opt/homebrew/anaconda3/bin/python",
            "/opt/anaconda3/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3"
        ]
        
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        
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
        if let userPath = UserDefaults.standard.string(forKey: "scriptsPath") {
            let scriptPath = (userPath as NSString).appendingPathComponent(script.filename)
            if FileManager.default.fileExists(atPath: scriptPath) {
                return scriptPath
            }
        }
        
        if let bundlePath = Bundle.main.path(forResource: script.filename.replacingOccurrences(of: ".py", with: ""), ofType: "py") {
            return bundlePath
        }
        
        let candidates = [
            NSHomeDirectory() + "/Library/Mobile Documents/com~apple~ScriptEditor2/Documents/Photo & Video Management",
            Bundle.main.bundlePath + "/../Scripts",
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
