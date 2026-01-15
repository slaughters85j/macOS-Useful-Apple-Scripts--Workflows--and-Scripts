import SwiftUI

struct ProcessButton: View {
    @Environment(AppState.self) private var appState
    
    private let runner = PythonRunner()
    
    var body: some View {
        Button {
            if appState.processingStatus == .running {
                Task { await runner.cancel() }
            } else {
                Task { await startProcessing() }
            }
        } label: {
            HStack(spacing: 8) {
                if appState.processingStatus == .running {
                    Image(systemName: "stop.fill")
                    Text("Cancel")
                } else {
                    Image(systemName: "play.fill")
                    Text("Process")
                }
            }
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!appState.canProcess && appState.processingStatus != .running)
    }
    
    @MainActor
    private func startProcessing() async {
        appState.processingStatus = .running
        appState.fileProgress = [:]
        
        for file in appState.videoFiles {
            appState.fileProgress[file.filename] = FileProgress(
                id: file.filename,
                status: .pending,
                segmentsCompleted: 0,
                segmentsTotal: 0,
                outputDir: nil
            )
        }
        
        do {
            switch appState.selectedMode {
            case .split:
                try await runSplitter()
            case .separate:
                try await runSeparator()
            case .gif:
                try await runGifConverter()
            }
        } catch {
            appState.processingStatus = .error(error.localizedDescription)
        }
    }
    
    @MainActor
    private func runSplitter() async throws {
        let files = appState.videoFiles.map(\.path)
        
        var fpsValues: [String: Double] = [:]
        if appState.fpsMode == .perFile {
            for file in appState.videoFiles {
                if let customFPS = file.customFPS {
                    fpsValues[file.filename] = customFPS
                }
            }
        }
        
        try await runner.runSplitter(
            files: files,
            splitMethod: appState.splitMethod == .duration ? "duration" : "segments",
            splitValue: appState.splitValue,
            fpsMode: appState.fpsMode == .single ? "single" : "per_file",
            fpsValue: appState.fpsValue,
            fpsValues: fpsValues,
            parallelJobs: appState.parallelJobs
        ) { event in
            Task { @MainActor in
                handleEvent(event)
            }
        }
    }
    
    @MainActor
    private func runSeparator() async throws {
        let files = appState.videoFiles.map(\.path)
        
        var sampleRates: [String: Int] = [:]
        if appState.sampleRateMode == .perFile {
            for file in appState.videoFiles {
                if let customRate = file.customSampleRate {
                    sampleRates[file.filename] = customRate.rawValue
                }
            }
        }
        
        try await runner.runSeparator(
            files: files,
            sampleRateMode: appState.sampleRateMode == .single ? "single" : "per_file",
            sampleRate: appState.sampleRate.rawValue,
            sampleRates: sampleRates,
            parallelJobs: appState.parallelJobs
        ) { event in
            Task { @MainActor in
                handleEvent(event)
            }
        }
    }
    
    @MainActor
    private func runGifConverter() async throws {
        let config = appState.buildGifConfig()
        
        try await runner.runGifConverter(config: config) { event in
            Task { @MainActor in
                handleEvent(event)
            }
        }
    }
    
    @MainActor
    private func handleEvent(_ event: PythonEvent) {
        switch event {
        case .start:
            break
            
        case .progress:
            break
            
        case .fileStart(let file, _):
            appState.updateFileProgress(fileId: file) { progress in
                progress.status = .processing
            }
            
        case .fileComplete(let file, let success, let outputDir, let segmentsCompleted, let segmentsTotal):
            appState.updateFileProgress(fileId: file) { progress in
                progress.status = success ? .completed : .error("Processing failed")
                progress.outputDir = outputDir
                if let completed = segmentsCompleted { progress.segmentsCompleted = completed }
                if let total = segmentsTotal { progress.segmentsTotal = total }
            }
            
        case .fileError(let file, let error):
            appState.updateFileProgress(fileId: file) { progress in
                progress.status = .error(error)
            }
            
        case .segmentStart(let file, _, let total):
            appState.updateFileProgress(fileId: file) { progress in
                progress.segmentsTotal = total
            }
            
        case .segmentComplete(let file, let segment, let total, _):
            appState.updateFileProgress(fileId: file) { progress in
                progress.segmentsCompleted = segment
                progress.segmentsTotal = total
            }
            
        case .complete(_, let successful, let failed):
            appState.processingStatus = .completed(successful: successful, failed: failed)
            
        case .error(let message):
            appState.processingStatus = .error(message)
        }
    }
}

#Preview {
    ProcessButton()
        .environment(AppState())
        .padding()
}
