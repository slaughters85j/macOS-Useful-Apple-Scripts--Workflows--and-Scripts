# VideoTools

A macOS SwiftUI app for batch video processing. Split, merge, separate A/V, generate animated GIFs and APNGs, inspect metadata, and rename batches of video and photo files — all through a native graphical interface. Runs entirely on Apple frameworks (AVFoundation, CoreMedia, ImageIO). No Python, no ffmpeg, no external dependencies.

## Features

### Video processing (batch)

- **Split** — slice a video into multiple segments by duration (e.g. every 60 seconds) or by segment count (e.g. exactly 5 equal parts), or simply re-encode the whole file. Supports stream copy (lossless, fast, keyframe-aligned) and re-encode via H.264 or HEVC. Per-file frame-rate overrides. Parallel segment export with a user-tunable concurrency cap.
- **Merge** — concatenate multiple videos into a single output. Stream-copy passthrough when inputs are codec-, resolution-, and frame-rate-compatible; otherwise re-encode via H.264 or HEVC with letterbox or crop/fill aspect handling. Audio gaps (inputs without audio) are filled with silence to preserve A/V sync.
- **Separate A/V** — extract lossless video-only and 16-bit PCM WAV audio copies of each input into a `<stem>_separated/` subfolder. Output container for the video matches the source (`.mov` stays `.mov`). Per-file audio sample-rate and channel overrides.
- **GIF / APNG** — convert clips into animated images with trim, cut segments, text overlay, speed multiplier, frame-rate and resolution control, custom fonts, and loop count. Native ImageIO quantization; no Python, no gifsicle.

### File management

- **Rename Videos / Rename Photos** — two-pass rename of batches using folder-name prefix, starting number, and zero-padding width. Collision detection with in-UI resolution. Find/Replace submode for scoped text substitution across filenames.

### Inspection

- **Metadata** — native AVFoundation-backed inspector showing duration, resolution, aspect ratio, video codec and profile, frame rate, bit rate, pixel format, color space, bit depth, and per-audio-track codec / channels / sample rate / bit rate. Thumbnail preview. Copy-to-clipboard of formatted metadata.
- **Media Player** — in-app video playback with Save Frame to capture a still as JPEG.

## Requirements

- **macOS 26.0** or later (deployment target).
- **Xcode 26** or later (Swift 6.0, filesystem-synchronized project groups).
- Apple Silicon recommended — VideoToolbox hardware video encode/decode accelerates every re-encode pipeline. Works on Intel Macs, but re-encodes rely on software fallbacks where hardware blocks aren't available.
- **No external runtime dependencies.** The app ships self-contained; no Python, ffmpeg, ffprobe, or Homebrew formulas required.

## Build

The repo includes a clean build wrapper at `/Users/system-backup/bin/xcodebuild-clean` that strips miniforge3's linker interference from the PATH. Use it rather than bare `xcodebuild`:

```bash
/Users/system-backup/bin/xcodebuild-clean -scheme VideoTools -destination 'platform=macOS' build
```

The Xcode project is at `VideoToolsApp/VideoTools.xcodeproj`. Opening it in Xcode and pressing Run works without further setup.

## Architecture

Every processing pipeline follows the same pattern — an actor orchestrator that consumes a `Sendable` config, emits `ProcessingEvent` values via a callback, and delegates work to pure-helper namespaces (for math) and small actor exporters (for AVFoundation I/O).

| Mode | Orchestrator | Supporting services |
|---|---|---|
| Split | `VideoSplitter` | `Services/Split/*` |
| Merge | `VideoMerger` | `Services/Merge/*` |
| Separate A/V | `VideoSeparator` | `Services/Separate/*` |
| GIF / APNG | `GifRenderer` | `Services/Gif/*` |
| Metadata | `VideoProber` | `Services/Separate/CodecNameResolver` |
| Rename | `FileRenamer` | (none) |

Cross-cutting:
- `ProcessingEvent` (`Services/ProcessingEvent.swift`) — the shared event enum every orchestrator emits.
- `AppState.currentTask` — outer task reference for cancellation; `ProcessButton`'s Cancel button calls `.cancel()` on it and every orchestrator observes cancellation via `try Task.checkCancellation()` at await points.

See [VideoTools/CLAUDE.md](VideoTools/CLAUDE.md) for a detailed walkthrough of each pipeline's stages, behavioral notes, and known limitations.

## Project conventions

- Service types are Swift actors for thread safety.
- Pure-math helpers are `enum` namespaces with static functions.
- Models are value types (`struct` / `enum`) in `Models/`. `AppState` and `ToolSettingsViewModel` are the only reference-type state containers.
- Every type that crosses actor boundaries is `Sendable` or `@unchecked Sendable` where the underlying type is immutable-after-creation (e.g. `CGImage`).
- Entitlements file is empty — no sandbox. The app needs unrestricted filesystem access for the user-selected source and destination directories.
- Each native-pipeline file includes a `#if DEBUG` validation harness (`FooTests.runAll()`) exercising pure-logic helpers. A separate `VideoToolsTests` target wraps these as XCTest entry points.

## License

No license specified. Private project.

## Credits

Built on AVFoundation, CoreMedia, CoreVideo, ImageIO, and SwiftUI. No third-party runtime dependencies.
