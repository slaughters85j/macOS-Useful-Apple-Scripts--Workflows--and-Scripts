import SwiftUI

struct MergerSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(ToolSettingsViewModel.self) private var toolSettings
    @State private var showingRestoreConfirmation = false

    var body: some View {
        @Bindable var state = appState
        @Bindable var settings = toolSettings

        VStack(alignment: .leading, spacing: 24) {
            // MARK: - Output File

            sectionHeader("Output File", icon: "doc")

            VStack(spacing: 8) {
                HStack {
                    Text("Filename")
                        .foregroundStyle(.secondary)

                    Spacer()

                    TextField("merged_output", text: $settings.mergeOutputFilename)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)
                        .multilineTextAlignment(.trailing)
                }

                Text("Extension will be added automatically based on codec (.mp4)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            Divider()

            // MARK: - Aspect Ratio Handling

            sectionHeader("Aspect Ratio Handling", icon: "aspectratio")

            Picker("Aspect", selection: $settings.mergeAspectMode) {
                ForEach(MergeAspectMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.blue)
                Text(aspectModeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            Divider()

            // MARK: - Output Codec

            sectionHeader("Output Codec", icon: "film")

            Picker("Codec", selection: $settings.mergeOutputCodec) {
                ForEach(OutputCodec.allCases) { codec in
                    Text(codec.rawValue).tag(codec)
                }
            }
            .pickerStyle(.segmented)

            if toolSettings.mergeOutputCodec == .copy {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Stream copy requires all inputs to have identical codec, resolution, and frame rate. Use H.264 or HEVC if inputs differ.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.orange.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            } else {
                Picker("Rate Control", selection: $settings.mergeQualityMode) {
                    ForEach(QualityMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if toolSettings.mergeQualityMode == .quality {
                    VStack(spacing: 4) {
                        HStack {
                            Text("Quality")
                                .foregroundStyle(.secondary)
                            Slider(value: $settings.mergeQualityValue, in: 1...100, step: 1)
                            Text("\(Int(toolSettings.mergeQualityValue))")
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

            // MARK: - Frame Rate

            sectionHeader("Frame Rate", icon: "speedometer")

            Group {
                HStack {
                    Text("Target FPS")
                        .foregroundStyle(.secondary)

                    Spacer()

                    TextField("FPS", value: $settings.mergeFpsValue, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .multilineTextAlignment(.trailing)
                }
            }
            .disabled(toolSettings.mergeOutputCodec == .copy)
            .opacity(toolSettings.mergeOutputCodec == .copy ? 0.4 : 1.0)

            Divider()

            // MARK: - Output Location

            sectionHeader("Output Location", icon: "folder")

            Picker("Output", selection: $state.mergeOutputLocation) {
                ForEach(MergeOutputLocation.allCases) { location in
                    Text(location.rawValue).tag(location)
                }
            }
            .pickerStyle(.segmented)

            if appState.mergeOutputLocation == .firstFile {
                Text("Output file will be placed in the same folder as the first input video.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                HStack {
                    if let dir = appState.mergeCustomOutputDir {
                        Text(dir.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()

                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.mergeCustomOutputDir = url
                        }
                    }
                }
            }

            Divider()

            Button("Restore Defaults") {
                showingRestoreConfirmation = true
            }
            .buttonStyle(.bordered)
            .confirmationDialog(
                "Restore Merge defaults?",
                isPresented: $showingRestoreConfirmation
            ) {
                Button("Restore Defaults", role: .destructive) {
                    toolSettings.restoreMergeDefaults()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This will reset Merge settings to their defaults.")
            }

            Spacer()
        }
    }

    private var aspectModeDescription: String {
        switch toolSettings.mergeAspectMode {
        case .letterbox:
            return "Pads with black bars to preserve all content when input resolutions differ."
        case .cropFill:
            return "Scales and crops to fill the target frame — some content may be cut off."
        }
    }

    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

#Preview {
    MergerSettingsView()
        .environment(AppState())
        .environment(ToolSettingsViewModel())
        .frame(width: 350)
        .padding()
}
