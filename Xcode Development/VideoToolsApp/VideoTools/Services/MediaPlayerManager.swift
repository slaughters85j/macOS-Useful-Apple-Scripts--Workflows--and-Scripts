import AVFoundation
import Combine
import SwiftUI

// MARK: - Deinit Cleanup Bag

/// Holds references that must be released in `deinit`, which runs nonisolated in Swift 6.
/// Using a plain reference type sidesteps the `@Observable` macro's restriction on
/// `nonisolated` mutable stored properties.
private final class PlayerCleanupBag {
    var timeObserverToken: Any?
    var endOfPlaybackObserver: NSObjectProtocol?
}

// MARK: - Media Player Manager

/// Manages AVPlayer lifecycle, playback state, and playlist navigation.
/// Injected via `.environment()` alongside `AppState`.
@Observable
@MainActor
final class MediaPlayerManager {

    // MARK: - Observable State (drives UI)

    var isPlaying: Bool = false
    var currentTime: Double = 0
    var duration: Double = 0
    var playbackSpeed: Double = 1.0
    var isLooping: Bool = false
    var isLoopingPlaylist: Bool = false
    var usePlaylist: Bool = true
    var currentFile: VideoFile?
    var volume: Double = 1.0 {
        didSet { player.volume = Float(volume) }
    }

    /// Set by MediaPlayerView during scrub drag to pause time updates
    var isScrubbing: Bool = false

    // MARK: - Private State

    private let player = AVPlayer()
    private var cancellables = Set<AnyCancellable>()
    private(set) var playlist: [VideoFile] = []
    private(set) var currentTrackIndex: Int = 0

    /// Holds observer tokens that must be cleaned up in deinit (nonisolated in Swift 6).
    private nonisolated(unsafe) let cleanup = PlayerCleanupBag()

    // MARK: - Read-Only Access

    /// Exposed for VideoPlayerRepresentable binding
    var avPlayer: AVPlayer { player }

    // MARK: - Init / Deinit

    init() {
        setupTimeObserver()
        setupRateObserver()
    }

    deinit {
        // deinit is nonisolated in Swift 6; use the cleanup bag to release observer tokens safely
        if let token = cleanup.timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let observer = cleanup.endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func play(file: VideoFile, playlist: [VideoFile]) {
        self.playlist = playlist
        self.currentTrackIndex = playlist.firstIndex(where: { $0.id == file.id }) ?? 0
        loadAndPlay(file: file)
    }

    func togglePlayPause() {
        if player.rate == 0 {
            player.rate = Float(playbackSpeed)
        } else {
            player.pause()
        }
    }

    func pause() {
        player.pause()
    }

    func seek(to time: Double) {
        let cmTime = CMTime(seconds: time, preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func nextTrack() {
        guard !playlist.isEmpty else { return }

        let nextIndex = currentTrackIndex + 1
        if nextIndex < playlist.count {
            currentTrackIndex = nextIndex
            loadAndPlay(file: playlist[nextIndex])
        } else if isLoopingPlaylist || isLooping {
            // Manual skip wraps if either loop mode is active
            currentTrackIndex = 0
            loadAndPlay(file: playlist[0])
        } else {
            // End of playlist, no wrap — pause and reset
            pause()
            seek(to: 0)
        }
    }

    func previousTrack() {
        guard !playlist.isEmpty else { return }

        // If more than 3 seconds in, restart current track
        if currentTime > 3 {
            seek(to: 0)
            if !isPlaying {
                player.rate = Float(playbackSpeed)
            }
            return
        }

        let prevIndex = currentTrackIndex - 1
        if prevIndex >= 0 {
            currentTrackIndex = prevIndex
            loadAndPlay(file: playlist[prevIndex])
        } else if isLoopingPlaylist || isLooping {
            // Manual skip wraps if either loop mode is active
            currentTrackIndex = playlist.count - 1
            loadAndPlay(file: playlist[currentTrackIndex])
        } else {
            // At start, no wrap — restart current track
            seek(to: 0)
        }
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        if isPlaying {
            player.rate = Float(speed)
        }
    }

    /// Keep playlist in sync with the live file list (called from ContentView onChange)
    func updatePlaylist(_ files: [VideoFile]) {
        playlist = files
        if let currentFile, let newIndex = files.firstIndex(where: { $0.id == currentFile.id }) {
            currentTrackIndex = newIndex
        }
    }

    /// Stop playback and release resources (called when inspector is dismissed)
    func stop() {
        pause()
        removeEndOfPlaybackObserver()
        player.replaceCurrentItem(with: nil)
        currentFile = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    // MARK: - Private Helpers

    private func loadAndPlay(file: VideoFile) {
        // Remove old observer before swapping items
        removeEndOfPlaybackObserver()

        let item = AVPlayerItem(url: file.url)
        player.replaceCurrentItem(with: item)
        currentFile = file

        // Observe end of playback for this item
        setupEndOfPlaybackObserver(for: item)

        // Start playback at the configured speed
        player.rate = Float(playbackSpeed)
    }

    // MARK: - Observers

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        cleanup.timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, !self.isScrubbing else { return }
                self.currentTime = time.seconds.isNaN ? 0 : time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   !itemDuration.isNaN {
                    self.duration = itemDuration
                }
            }
        }
    }

    private func setupRateObserver() {
        player.publisher(for: \.rate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRate in
                Task { @MainActor in
                    self?.isPlaying = newRate > 0
                }
            }
            .store(in: &cancellables)
    }

    private func setupEndOfPlaybackObserver(for item: AVPlayerItem) {
        cleanup.endOfPlaybackObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackEnd()
            }
        }
    }

    private func removeEndOfPlaybackObserver() {
        if let observer = cleanup.endOfPlaybackObserver {
            NotificationCenter.default.removeObserver(observer)
            cleanup.endOfPlaybackObserver = nil
        }
    }

    private func handlePlaybackEnd() {
        if isLooping {
            // Loop = repeat current track, always. Overrides everything.
            seek(to: 0)
            player.rate = Float(playbackSpeed)
        } else if usePlaylist {
            // Playlist mode — auto-advance to next track
            let nextIndex = currentTrackIndex + 1
            if nextIndex < playlist.count {
                currentTrackIndex = nextIndex
                loadAndPlay(file: playlist[nextIndex])
            } else if isLoopingPlaylist {
                // End of playlist + Loop Playlist → wrap to first track
                currentTrackIndex = 0
                loadAndPlay(file: playlist[0])
            } else {
                // End of playlist, no wrap — stop
                pause()
                seek(to: 0)
            }
        } else {
            // No loop, no playlist — stop
            pause()
            seek(to: 0)
        }
    }
}
