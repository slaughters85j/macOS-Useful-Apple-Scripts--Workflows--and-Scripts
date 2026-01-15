import SwiftUI

struct SettingsView: View {
    @AppStorage("pythonPath") private var pythonPath: String = ""
    @AppStorage("scriptsPath") private var scriptsPath: String = ""
    
    @State private var detectedPython: String?
    @State private var detectedScripts: String?
    @State private var pythonVersion: String?
    @State private var isValidatingPython = false
    @State private var isValidatingScripts = false
    @State private var pythonError: String?
    @State private var scriptsError: String?
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Python Executable")
                        .font(.headline)
                    
                    HStack {
                        TextField("Auto-detect or enter path...", text: $pythonPath)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            browsePython()
                        }
                        
                        Button("Detect") {
                            detectPython()
                        }
                    }
                    
                    if isValidatingPython {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Validating...")
                                .foregroundStyle(.secondary)
                        }
                    } else if let version = pythonVersion {
                        Label(version, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if let error = pythonError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if let detected = detectedPython {
                        Label("Detected: \(detected)", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("The app needs Python 3 with the ffmpeg-python package installed.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scripts Location")
                        .font(.headline)
                    
                    HStack {
                        TextField("Use bundled scripts or enter path...", text: $scriptsPath)
                            .textFieldStyle(.roundedBorder)
                        
                        Button("Browse...") {
                            browseScripts()
                        }
                        
                        Button("Reset") {
                            scriptsPath = ""
                            scriptsError = nil
                        }
                    }
                    
                    if isValidatingScripts {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Checking...")
                                .foregroundStyle(.secondary)
                        }
                    } else if let error = scriptsError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    } else if scriptsPath.isEmpty {
                        Label("Using bundled scripts", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Using custom location", systemImage: "folder")
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("Leave empty to use the scripts bundled with the app. Set a custom path if you want to use modified scripts.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("FFmpeg / FFprobe")
                        .font(.headline)
                    
                    Text("The app auto-detects ffmpeg and ffprobe from common installation paths (Homebrew, MacPorts, etc). Ensure ffmpeg is installed on your system.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    Button("Check FFmpeg Installation") {
                        checkFFmpeg()
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 550, height: 450)
        .onAppear {
            detectPython()
            validateCurrentSettings()
        }
        .onChange(of: pythonPath) { _, newValue in
            if !newValue.isEmpty {
                validatePython(path: newValue)
            } else {
                pythonVersion = nil
                pythonError = nil
            }
        }
        .onChange(of: scriptsPath) { _, newValue in
            if !newValue.isEmpty {
                validateScripts(path: newValue)
            } else {
                scriptsError = nil
            }
        }
    }
    
    private func browsePython() {
        let panel = NSOpenPanel()
        panel.title = "Select Python Executable"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/usr/local/bin")
        
        if panel.runModal() == .OK, let url = panel.url {
            pythonPath = url.path
        }
    }
    
    private func browseScripts() {
        let panel = NSOpenPanel()
        panel.title = "Select Scripts Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        
        if panel.runModal() == .OK, let url = panel.url {
            scriptsPath = url.path
        }
    }
    
    private func detectPython() {
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
                detectedPython = path
                if pythonPath.isEmpty {
                    pythonPath = path
                }
                validatePython(path: path)
                return
            }
        }
        
        detectedPython = nil
        pythonError = "No Python installation detected"
    }
    
    private func validateCurrentSettings() {
        if !pythonPath.isEmpty {
            validatePython(path: pythonPath)
        }
        if !scriptsPath.isEmpty {
            validateScripts(path: scriptsPath)
        }
    }
    
    private func validatePython(path: String) {
        isValidatingPython = true
        pythonError = nil
        pythonVersion = nil
        
        Task {
            let result = await checkPythonVersion(path: path)
            await MainActor.run {
                isValidatingPython = false
                switch result {
                case .success(let version):
                    pythonVersion = version
                case .failure(let error):
                    pythonError = error.localizedDescription
                }
            }
        }
    }
    
    private func checkPythonVersion(path: String) async -> Result<String, Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return .success(output)
            } else {
                return .failure(NSError(domain: "VideoTools", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not determine version"]))
            }
        } catch {
            return .failure(error)
        }
    }
    
    private func validateScripts(path: String) {
        isValidatingScripts = true
        scriptsError = nil
        
        let splitterPath = (path as NSString).appendingPathComponent("video_splitter_batch.py")
        let separatorPath = (path as NSString).appendingPathComponent("video_audio_separator_batch.py")
        
        var missing: [String] = []
        if !FileManager.default.fileExists(atPath: splitterPath) {
            missing.append("video_splitter_batch.py")
        }
        if !FileManager.default.fileExists(atPath: separatorPath) {
            missing.append("video_audio_separator_batch.py")
        }
        
        isValidatingScripts = false
        
        if !missing.isEmpty {
            scriptsError = "Missing: \(missing.joined(separator: ", "))"
        }
    }
    
    private func checkFFmpeg() {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg"
        ]
        
        var found: String?
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                found = path
                break
            }
        }
        
        let alert = NSAlert()
        if let path = found {
            alert.messageText = "FFmpeg Found"
            alert.informativeText = "FFmpeg is installed at:\n\(path)"
            alert.alertStyle = .informational
        } else {
            alert.messageText = "FFmpeg Not Found"
            alert.informativeText = "FFmpeg was not found in common locations. Install it via Homebrew:\n\nbrew install ffmpeg"
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

#Preview {
    SettingsView()
}
