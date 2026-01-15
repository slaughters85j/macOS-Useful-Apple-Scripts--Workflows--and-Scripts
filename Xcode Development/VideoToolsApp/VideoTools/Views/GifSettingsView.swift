import SwiftUI

struct GifSettingsView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        // Force re-render when metadata loads asynchronously
        let _ = appState.updateVersion

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // MARK: - Trimming Section (moved to top for prominence)
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Trimming", icon: "timeline.selection")
                    
                    if let url = appState.videoFiles.first?.url,
                       let duration = appState.videoFiles.first?.metadata?.duration {
                        TrimTimelineView(
                            trimStart: $state.gifTrimStart,
                            trimEnd: $state.gifTrimEnd,
                            cutSegments: $state.gifCutSegments,
                            duration: duration,
                            videoURL: url
                        )
                    } else {
                        Text("Add a video file to enable trimming")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                
                Divider()
                
                // MARK: - Resolution Section
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Resolution", icon: "aspectratio")
                    
                    Picker("Mode", selection: $state.gifResolutionMode) {
                        ForEach(GifResolutionMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    switch state.gifResolutionMode {
                    case .original:
                        Text("Output will match source video dimensions")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        
                    case .scale:
                        HStack {
                            Text("Scale")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Slider(value: $state.gifScalePercent, in: 10...100, step: 5)
                                .frame(width: 150)
                            Text("\(Int(state.gifScalePercent))%")
                                .monospacedDigit()
                                .frame(width: 45, alignment: .trailing)
                        }
                        
                    case .width:
                        HStack {
                            Text("Width (px)")
                                .foregroundStyle(.secondary)
                            Spacer()
                            TextField("Width", value: $state.gifFixedWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Height calculated to maintain aspect ratio")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        
                    case .custom:
                        HStack {
                            Text("Width")
                                .foregroundStyle(.secondary)
                            TextField("W", value: $state.gifCustomWidth, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("×")
                            TextField("H", value: $state.gifCustomHeight, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                            Text("px")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                Divider()
                
                // MARK: - Timing Section
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Timing", icon: "speedometer")
                    
                    HStack {
                        Text("Frame Rate")
                            .foregroundStyle(.secondary)
                        Spacer()
                        TextField("FPS", value: $state.gifFrameRate, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        Text("fps")
                            .foregroundStyle(.secondary)
                    }
                    
                    Text("10-15 fps typical for GIFs. Higher = larger file size.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    HStack {
                        Text("Speed")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Speed", selection: $state.gifSpeedMultiplier) {
                            Text("0.5×").tag(0.5)
                            Text("0.75×").tag(0.75)
                            Text("1×").tag(1.0)
                            Text("1.25×").tag(1.25)
                            Text("1.5×").tag(1.5)
                            Text("2×").tag(2.0)
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
                
                Divider()
                
                // MARK: - Quality Section
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Quality", icon: "paintpalette")
                    
                    HStack {
                        Text("Colors")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Slider(value: $state.gifColorCount, in: 16...256, step: 16)
                            .frame(width: 150)
                        Text("\(Int(state.gifColorCount))")
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)
                    }
                    
                    Text("GIFs support max 256 colors. Fewer colors = smaller file.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    
                    HStack {
                        Text("Dithering")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker("Dither", selection: $state.gifDitherMethod) {
                            ForEach(GifDitherMethod.allCases) { method in
                                Text(method.rawValue).tag(method)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)
                    }
                }
                
                Divider()
                
                // MARK: - Loop Section
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader("Looping", icon: "repeat")
                    
                    Picker("Loop", selection: $state.gifLoopMode) {
                        ForEach(GifLoopMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    if state.gifLoopMode == .custom {
                        HStack {
                            Text("Loop Count")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Stepper("\(state.gifLoopCount)", value: $state.gifLoopCount, in: 1...100)
                                .frame(width: 120)
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
    
    // MARK: - Helpers
    
    private func sectionHeader(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }
}

#Preview {
    GifSettingsView()
        .environment(AppState())
        .frame(width: 380)
        .padding()
}
