import SwiftUI

// MARK: - SettingsView
//
// VideoTools used to run Python subprocesses and shell out to ffmpeg/ffprobe
// for its processing pipelines. The Settings window exposed user-configurable
// paths for all three (Python executable, scripts folder, ffmpeg binary).
//
// After the native migration, all processing runs on AVFoundation and
// CoreMedia — framework code that ships with macOS. There are no external
// binaries to locate or configure. The Settings window is kept as a
// placeholder so the menu item still opens something; the stored
// `pythonPath` and `scriptsPath` UserDefaults keys are left intact (unused
// but harmless) in case future features want them back.

struct SettingsView: View {
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Fully native", systemImage: "checkmark.seal.fill")
                        .font(.headline)
                        .foregroundStyle(.green)
                    Text("VideoTools no longer depends on Python, ffmpeg, or ffprobe. All processing (Split, Merge, Separate A/V, GIF/APNG, Metadata) runs on AVFoundation and CoreMedia frameworks built into macOS.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("No paths to configure. No dependencies to install.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 220)
    }
}

#Preview {
    SettingsView()
}
