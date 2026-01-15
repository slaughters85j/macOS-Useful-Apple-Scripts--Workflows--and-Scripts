import SwiftUI

struct SplitterSettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        VStack(alignment: .leading, spacing: 24) {
            sectionHeader("Split Method", icon: "scissors")
            
            Picker("Method", selection: $state.splitMethod) {
                ForEach(SplitMethod.allCases) { method in
                    Text(method.rawValue).tag(method)
                }
            }
            .pickerStyle(.segmented)
            
            HStack {
                Text(appState.splitMethod == .duration ? "Duration (seconds)" : "Number of Segments")
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                TextField(
                    "Value",
                    value: $state.splitValue,
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .multilineTextAlignment(.trailing)
            }
            
            Divider()
            
            sectionHeader("Frame Rate", icon: "speedometer")
            
            Picker("FPS Mode", selection: $state.fpsMode) {
                ForEach(FPSMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            
            if appState.fpsMode == .single {
                HStack {
                    Text("Target FPS")
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                    
                    TextField("FPS", value: $state.fpsValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
            } else {
                perFileFPSSettings
            }
            
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
            
            Text("Higher values process faster but use more system resources")
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
    private var perFileFPSSettings: some View {
        if appState.videoFiles.isEmpty {
            Text("Add files to configure individual FPS values")
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
                        
                        TextField(
                            "FPS",
                            value: Binding(
                                get: { 
                                    appState.videoFiles.first { $0.id == file.id }?.customFPS ?? appState.fpsValue 
                                },
                                set: { newValue in
                                    if let idx = appState.videoFiles.firstIndex(where: { $0.id == file.id }) {
                                        appState.videoFiles[idx].customFPS = newValue
                                    }
                                }
                            ),
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
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
    SplitterSettingsView()
        .environment(AppState())
        .frame(width: 350)
        .padding()
}
