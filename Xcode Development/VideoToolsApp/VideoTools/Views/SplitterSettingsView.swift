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

            switch appState.splitMethod {
            case .duration:
                VStack(spacing: 8) {
                    HStack {
                        Text("Duration")
                            .foregroundStyle(.secondary)

                        Spacer()

                        TextField(
                            "Value",
                            value: $state.splitValue,
                            format: .number
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)

                        Picker("", selection: $state.splitDurationUnit) {
                            ForEach(DurationUnit.allCases) { unit in
                                Text(unit.rawValue).tag(unit)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }

                    if appState.splitDurationUnit == .minutes {
                        Text("= \(Int(appState.splitValue * 60)) seconds per segment")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

            case .segments:
                HStack {
                    Text("Number of Segments")
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

            case .reencodeOnly:
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text(reencodeOnlyInfoText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }

            Divider()

            sectionHeader("Output Codec", icon: "film")

            Picker("Codec", selection: $state.outputCodec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            if appState.outputCodec == .copy {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.blue)
                    Text("Stream copy is lossless and fast. Segments snap to nearest keyframe. Frame rate cannot be changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Picker("Rate Control", selection: $state.qualityMode) {
                    ForEach(QualityMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if appState.qualityMode == .quality {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Quality")
                                .foregroundStyle(.secondary)
                            Slider(value: $state.qualityValue, in: 1...100, step: 1)
                            Text("\(Int(appState.qualityValue))")
                                .monospacedDigit()
                                .frame(width: 30)
                        }
                        Text("Higher = better quality, larger files. 65 is visually equivalent to source for most content.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Divider()

            sectionHeader("Frame Rate", icon: "speedometer")

            Group {
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
            }
            .disabled(appState.outputCodec == .copy)
            .opacity(appState.outputCodec == .copy ? 0.4 : 1.0)
            
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

            Divider()

            sectionHeader("Output Location", icon: "folder")

            Picker("Output", selection: $state.outputFolderMode) {
                ForEach(OutputFolderMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(appState.outputFolderMode == .perFile
                 ? "Each video's output goes into a subfolder named <filename>_parts."
                 : "All output files are placed next to the source files in the same folder.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()
        }
    }
    
    private var reencodeOnlyInfoText: String {
        switch appState.outputCodec {
        case .copy:
            return "The video will be remuxed (stream copied) without re-encoding or splitting."
        case .h264:
            return "The video will be re-encoded to H.264 without splitting."
        case .hevc:
            return "The video will be re-encoded to HEVC (H.265) without splitting."
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
