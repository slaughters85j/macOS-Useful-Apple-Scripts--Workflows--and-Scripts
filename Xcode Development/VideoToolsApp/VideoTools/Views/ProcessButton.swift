import SwiftUI

struct ProcessButton: View {
    @Environment(AppState.self) private var appState

    private let runner = PythonRunner()
    private let renamer = FileRenamer()

    private var buttonLabel: String {
        switch appState.selectedMode {
        case .renameVideos, .renamePhotos: return "Rename"
        default: return "Process"
        }
    }

    private var buttonIcon: String {
        switch appState.selectedMode {
        case .renameVideos, .renamePhotos: return "pencil.line"
        default: return "play.fill"
        }
    }

    var body: some View {
        @Bindable var state = appState

        Button {
            if appState.processingStatus == .running {
                Task { await runner.cancel() }
            } else if appState.selectedMode.isFolderBased {
                appState.showRenameConfirmation = true
            } else {
                Task { await startProcessing() }
            }
        } label: {
            HStack(spacing: 8) {
                if appState.processingStatus == .running {
                    Image(systemName: "stop.fill")
                    Text("Cancel")
                } else {
                    Image(systemName: buttonIcon)
                    Text(buttonLabel)
                }
            }
            .frame(minWidth: 100)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!appState.canProcess && appState.processingStatus != .running)
        .alert("Confirm Rename", isPresented: $state.showRenameConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Rename", role: .destructive) {
                Task { await startProcessing() }
            }
        } message: {
            let count = appState.activeRenameFolder?.discoveredFiles.count ?? 0
            Text("Rename \(count) file\(count == 1 ? "" : "s")? This cannot be undone.")
        }
    }
    
    @MainActor
    private func startProcessing() async {
        appState.processingStatus = .running
        appState.fileProgress = [:]

        // Only set up file progress tracking for video-file-based modes
        if !appState.selectedMode.isFolderBased {
            for file in appState.videoFiles {
                appState.fileProgress[file.filename] = FileProgress(
                    id: file.filename,
                    status: .pending,
                    segmentsCompleted: 0,
                    segmentsTotal: 0,
                    outputDir: nil
                )
            }
        }
        
        do {
            switch appState.selectedMode {
            case .split:
                try await runSplitter()
            case .separate:
                try await runSeparator()
            case .gif:
                try await runGifConverter()
            case .renameVideos, .renamePhotos:
                await runRename()
            case .metadata:
                break
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
        
        // Re-encode only sends 1 segment (full video, no split)
        let splitMethod: String
        let splitValue: Double
        switch appState.splitMethod {
        case .duration:
            splitMethod = "duration"
            splitValue = appState.splitValueInSeconds
        case .segments:
            splitMethod = "segments"
            splitValue = appState.splitValue
        case .reencodeOnly:
            splitMethod = "segments"
            splitValue = 1
        }

        try await runner.runSplitter(
            files: files,
            splitMethod: splitMethod,
            splitValue: splitValue,
            fpsMode: appState.fpsMode == .single ? "single" : "per_file",
            fpsValue: appState.fpsValue,
            fpsValues: fpsValues,
            parallelJobs: appState.parallelJobs,
            outputCodec: appState.outputCodec.configValue,
            qualityMode: appState.qualityMode.configValue,
            qualityValue: appState.qualityValue,
            outputFolderMode: appState.outputFolderMode.configValue
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
            audioChannels: appState.audioChannelMode.rawValue,
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
    private func runRename() async {
        guard let folder = appState.activeRenameFolder else {
            appState.processingStatus = .error("No folder selected")
            return
        }

        let hasCollisions = folder.discoveredFiles.contains { $0.status == .collision }
        if hasCollisions {
            appState.processingStatus = .error("Resolve naming collisions before renaming")
            return
        }

        let result = await renamer.performRenames(files: folder.discoveredFiles)
        appState.processingStatus = .completed(
            successful: result.successCount,
            failed: result.failCount
        )

        // Refresh the folder to show updated state
        if result.successCount > 0 {
            appState.selectFolder(url: folder.url, forMode: appState.selectedMode)
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
