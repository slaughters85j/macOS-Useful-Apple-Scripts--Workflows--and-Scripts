import SwiftUI
import AVFoundation

/// Right panel view for metadata mode — rich display of video/audio stream details.
struct MetadataSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var thumbnail: NSImage?
    @State private var copiedToClipboard = false

    var body: some View {
        if let file = appState.metadataFile {
            if file.isLoading {
                loadingView
            } else if let meta = file.metadata {
                metadataContent(file: file, meta: meta)
            } else {
                errorView
            }
        } else {
            emptyView
        }
    }

    // MARK: - States

    private var loadingView: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text("Analyzing video...")
                .font(.headline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Could not read metadata")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Ensure ffprobe is installed and the file is a valid video.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "sidebar.squares.left")
                .font(.system(size: 36))
                .foregroundStyle(.quaternary)
            Text("Select a file to view metadata")
                .font(.headline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Main Content

    private func metadataContent(file: MetadataFile, meta: VideoMetadata) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Thumbnail
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .frame(maxWidth: .infinity)
            }

            // File info header
            fileInfoSection(file: file, meta: meta)

            Divider()

            // Video stream
            videoStreamSection(meta: meta)

            // Audio stream
            if meta.hasAudio {
                Divider()
                audioStreamSection(meta: meta)
            }

            Divider()

            // Actions
            actionsSection(meta: meta)
        }
        .onAppear {
            generateThumbnail(for: file.url)
        }
        .onChange(of: appState.metadataFile?.id) { _, _ in
            thumbnail = nil
            if let url = appState.metadataFile?.url {
                generateThumbnail(for: url)
            }
        }
    }

    // MARK: - Sections

    private func fileInfoSection(file: MetadataFile, meta: VideoMetadata) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("File Information", systemImage: "doc.text")
                    .font(.headline)

                metaRow("Duration", meta.durationFormatted)
                metaRow("Resolution", "\(meta.resolution) (\(meta.aspectRatio))")

                if let size = file.fileSize {
                    metaRow("File Size", formatFileSize(size))
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func videoStreamSection(meta: VideoMetadata) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Video Stream", systemImage: "film")
                    .font(.headline)

                metaRow("Codec", meta.videoCodec.uppercased())

                if let profile = meta.codecProfile {
                    metaRow("Profile", profile)
                }

                metaRow("Frame Rate", meta.frameRateFormatted)
                metaRow("Bit Rate", meta.bitRateMbps)

                if let pixFmt = meta.pixelFormat {
                    metaRow("Pixel Format", pixFmt)
                }

                if let bitDepth = meta.bitDepth {
                    metaRow("Bit Depth", "\(bitDepth)-bit")
                }

                if let colorSpace = meta.colorSpace {
                    metaRow("Color Space", colorSpace)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func audioStreamSection(meta: VideoMetadata) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label("Audio Stream", systemImage: "waveform")
                    .font(.headline)

                if let codec = meta.audioCodec {
                    metaRow("Codec", codec.uppercased())
                }

                if let formatted = meta.audioSampleRateFormatted {
                    metaRow("Sample Rate", formatted)
                }

                if let channels = meta.audioChannelsFormatted {
                    metaRow("Channels", channels)
                }

                if let bitRate = meta.audioBitRateFormatted {
                    metaRow("Bit Rate", bitRate)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func actionsSection(meta: VideoMetadata) -> some View {
        HStack {
            Button {
                copyMetadataToClipboard(meta: meta)
            } label: {
                Label(
                    copiedToClipboard ? "Copied!" : "Copy to Clipboard",
                    systemImage: copiedToClipboard ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)

            Spacer()
        }
    }

    // MARK: - Helpers

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100, alignment: .leading)
            Spacer()
            Text(value)
                .font(.system(.subheadline, design: .monospaced, weight: .medium))
                .textSelection(.enabled)
        }
    }

    private func generateThumbnail(for url: URL) {
        Task.detached {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 640, height: 360)

            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                await MainActor.run {
                    self.thumbnail = nsImage
                }
            } catch {
                print("MetadataSettingsView: Failed to generate thumbnail: \(error)")
            }
        }
    }

    private func copyMetadataToClipboard(meta: VideoMetadata) {
        var lines: [String] = []
        if let file = appState.metadataFile {
            lines.append("File: \(file.filename)")
            lines.append("Path: \(file.path)")
            if let size = file.fileSize {
                lines.append("Size: \(formatFileSize(size))")
            }
        }
        lines.append("")
        lines.append("--- Video ---")
        lines.append("Resolution: \(meta.resolution) (\(meta.aspectRatio))")
        lines.append("Codec: \(meta.videoCodec)")
        if let profile = meta.codecProfile { lines.append("Profile: \(profile)") }
        lines.append("Frame Rate: \(meta.frameRateFormatted)")
        lines.append("Bit Rate: \(meta.bitRateMbps)")
        lines.append("Duration: \(meta.durationFormatted)")
        if let pf = meta.pixelFormat { lines.append("Pixel Format: \(pf)") }
        if let bd = meta.bitDepth { lines.append("Bit Depth: \(bd)-bit") }
        if let cs = meta.colorSpace { lines.append("Color Space: \(cs)") }

        if meta.hasAudio {
            lines.append("")
            lines.append("--- Audio ---")
            if let c = meta.audioCodec { lines.append("Codec: \(c)") }
            if let sr = meta.audioSampleRateFormatted { lines.append("Sample Rate: \(sr)") }
            if let ch = meta.audioChannelsFormatted { lines.append("Channels: \(ch)") }
            if let br = meta.audioBitRateFormatted { lines.append("Bit Rate: \(br)") }
        }

        let text = lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation {
            copiedToClipboard = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                copiedToClipboard = false
            }
        }
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

#Preview {
    MetadataSettingsView()
        .environment(AppState())
        .frame(width: 380, height: 600)
        .padding()
}
