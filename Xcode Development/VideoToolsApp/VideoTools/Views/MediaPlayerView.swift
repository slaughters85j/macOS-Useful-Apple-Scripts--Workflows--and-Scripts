import SwiftUI
import AVFoundation

// MARK: - Media Player View (Inspector Sidebar Content)

struct MediaPlayerView: View {
    @Environment(MediaPlayerManager.self) private var playerManager
    @Environment(AppState.self) private var appState

    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var scrubDebounce: Task<Void, Never>?
    @State private var saveFrameMessage: String?
    @State private var saveFrameTask: Task<Void, Never>?

    var body: some View {
        @Bindable var pm = playerManager

        VStack(spacing: 0) {
            // MARK: - Header with dismiss button
            HStack {
                Text("Media Player")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.isMediaPlayerVisible = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close media player")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 4)

            // MARK: - Video Display (takes all available vertical space)
            videoDisplay
                .padding(.horizontal)

            // MARK: - Controls (compact, pinned to bottom)
            VStack(spacing: 12) {
                nowPlayingInfo
                scrubBar
                transportControls
                saveFrameButton

                Divider()

                speedControl
                playbackToggles
                volumeControl
            }
            .padding()
        }
    }

    // MARK: - Video Display

    private var videoDisplay: some View {
        ZStack {
            Color.black

            if playerManager.currentFile != nil {
                VideoPlayerRepresentable(player: playerManager.avPlayer)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "play.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(.tertiary)
                    Text("Select a file to play")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Now Playing Info

    private var nowPlayingInfo: some View {
        VStack(spacing: 2) {
            Text(playerManager.currentFile?.filename ?? "No file selected")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if !playerManager.playlist.isEmpty {
                Text("Track \(playerManager.currentTrackIndex + 1) of \(playerManager.playlist.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Scrub Bar

    private var scrubBar: some View {
        let displayTime = isScrubbing ? scrubTime : playerManager.currentTime
        let maxDuration = max(playerManager.duration, 0.01)

        return VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { displayTime },
                    set: { newValue in
                        scrubTime = newValue

                        // Enter scrub mode on first drag movement
                        if !isScrubbing {
                            isScrubbing = true
                            playerManager.isScrubbing = true
                        }

                        // Debounce: when the setter stops firing (~200ms), the drag ended
                        scrubDebounce?.cancel()
                        scrubDebounce = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(200))
                            guard !Task.isCancelled else { return }
                            playerManager.seek(to: scrubTime)
                            playerManager.isScrubbing = false
                            isScrubbing = false
                        }
                    }
                ),
                in: 0...maxDuration
            )

            HStack {
                Text(formatTime(displayTime))
                Spacer()
                Text(formatTime(playerManager.duration))
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 28) {
            Button {
                playerManager.previousTrack()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Previous track")
            .disabled(playerManager.currentFile == nil)

            Button {
                playerManager.togglePlayPause()
            } label: {
                Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title)
            }
            .buttonStyle(.plain)
            .help(playerManager.isPlaying ? "Pause" : "Play")
            .disabled(playerManager.currentFile == nil)

            Button {
                playerManager.nextTrack()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("Next track")
            .disabled(playerManager.currentFile == nil)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Save Frame Button

    private var saveFrameButton: some View {
        HStack(spacing: 8) {
            Button("Save Frame") {
                // Cancel any in-flight feedback timer
                saveFrameTask?.cancel()
                saveFrameTask = Task { @MainActor in
                    do {
                        let url = try await playerManager.saveCurrentFrame()
                        saveFrameMessage = "Saved: \(url.lastPathComponent)"
                    } catch {
                        saveFrameMessage = "Failed: \(error.localizedDescription)"
                    }
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    saveFrameMessage = nil
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(playerManager.currentFile == nil)
            .help("Save current frame as JPEG next to the source file")

            if let message = saveFrameMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .transition(.opacity)
            }

            Spacer()
        }
        .animation(.easeInOut(duration: 0.2), value: saveFrameMessage)
    }

    // MARK: - Speed Control

    private var speedControl: some View {
        @Bindable var pm = playerManager

        return HStack(spacing: 8) {
            Text("Speed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)

            Slider(
                value: $pm.playbackSpeed,
                in: 0.25...2.0,
                step: 0.25
            )
            .onChange(of: playerManager.playbackSpeed) { _, newSpeed in
                playerManager.setSpeed(newSpeed)
            }

            Text(String(format: "%.2fx", playerManager.playbackSpeed))
                .font(.caption)
                .monospacedDigit()
                .frame(width: 45, alignment: .trailing)
        }
    }

    // MARK: - Playback Toggles

    private var playbackToggles: some View {
        @Bindable var pm = playerManager

        return HStack {
            Toggle("Loop", isOn: $pm.isLooping)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Repeat the current track")
                .onChange(of: playerManager.isLooping) { _, isOn in
                    if isOn { playerManager.isLoopingPlaylist = false }
                }

            Toggle("Loop Playlist", isOn: $pm.isLoopingPlaylist)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Loop through all tracks")
                .onChange(of: playerManager.isLoopingPlaylist) { _, isOn in
                    if isOn { playerManager.isLooping = false }
                }

            Spacer()

            Toggle("Playlist", isOn: $pm.usePlaylist)
                .toggleStyle(.checkbox)
                .font(.caption)
                .help("Auto-advance to next track")
        }
    }

    // MARK: - Volume Control

    private var volumeControl: some View {
        @Bindable var pm = playerManager

        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Slider(value: $pm.volume, in: 0...1)

            Image(systemName: "speaker.wave.3.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite else { return "0:00" }
        let totalSeconds = Int(max(0, seconds))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

#Preview {
    MediaPlayerView()
        .environment(MediaPlayerManager())
        .environment(AppState())
        .frame(width: 400, height: 600)
}
