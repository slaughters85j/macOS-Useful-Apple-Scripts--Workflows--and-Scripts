import SwiftUI

struct SeparatorSettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Audio Sample Rate", icon: "waveform")
            
            Picker("Mode", selection: $state.sampleRateMode) {
                ForEach(SampleRateMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            
            if appState.sampleRateMode == .single {
                Picker("Sample Rate", selection: $state.sampleRate) {
                    ForEach(SampleRate.allCases) { rate in
                        Text(rate.displayName).tag(rate)
                    }
                }
                .pickerStyle(.menu)
            } else {
                perFileSampleRateSettings
            }
            
            Divider()
            
            sectionHeader("Output", icon: "folder")
            
            VStack(alignment: .leading, spacing: 8) {
                Label("Video: {filename}_video.mp4", systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Label("Audio: {filename}_audio.wav", systemImage: "waveform.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Text("Files are saved to {filename}_separated/ folder")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            
            Divider()
            
            sectionHeader("Processing", icon: "cpu")
            
            HStack {
                Text("Parallel Jobs")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Stepper(
                    "\(appState.parallelJobs)",
                    value: $state.parallelJobs,
                    in: 1...8
                )
                .frame(width: 120)
            }
            
            Text("Each file is processed in parallel. Higher values use more resources.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            Spacer()
        }
    }
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
    
    @ViewBuilder
    private var perFileSampleRateSettings: some View {
        if appState.videoFiles.isEmpty {
            Text("Add files to configure individual sample rates")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 8)
        } else {
            VStack(spacing: 8) {
                ForEach(appState.videoFiles) { file in
                    HStack {
                        Text(file.filename)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Picker(
                            "",
                            selection: Binding(
                                get: { 
                                    appState.videoFiles.first { $0.id == file.id }?.customSampleRate ?? appState.sampleRate 
                                },
                                set: { newValue in
                                    if let idx = appState.videoFiles.firstIndex(where: { $0.id == file.id }) {
                                        appState.videoFiles[idx].customSampleRate = newValue
                                    }
                                }
                            )
                        ) {
                            ForEach(SampleRate.allCases) { rate in
                                Text("\(rate.rawValue) Hz").tag(rate)
                            }
                        }
                        .frame(width: 120)
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

#Preview {
    SeparatorSettingsView()
        .environment(AppState())
        .frame(width: 350)
        .padding()
}
