# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**CRITICAL**: Never run bare `xcodebuild` or `swift build` directly. Miniforge3 contaminates the PATH with its own linker, causing cryptic build failures. Always use the clean build wrapper:

```bash
/Users/system-backup/bin/xcodebuild-clean -scheme VideoTools -destination 'platform=macOS' build
```

The Xcode project file is at the repo root: `VideoTools.xcodeproj`. There is no SPM Package.swift — this is a pure Xcode project.

## Project Overview

VideoTools is a **macOS-only SwiftUI app** (deployment target: macOS 26.0, Swift 6.0, bundle ID: `com.UBSAnalytics.VideoTools`) that provides a GUI for batch video processing operations. It is a **hybrid native-plus-Python app**: the GIF pipeline is fully native (AVFoundation + ImageIO), while the remaining video operations (split, separate A/V, merge) still delegate to bundled Python scripts that call `ffmpeg` / `ffprobe`.

The native migration is in progress. Any new feature should prefer native Swift unless there is a compelling reason (e.g. a third-party codec ffmpeg handles and AVFoundation does not) to stay on the Python path.

### Tool Modes

Modes are declared in `ToolMode` and routed by `ContentView` and `ProcessButton`.

- **Video Processing (Python-backed)**: Split, Separate A/V, Merge
- **Video Processing (native)**: GIF (GIF or APNG output)
- **File Management**: Rename Videos, Rename Photos (batch rename using folder-name prefix with collision detection, plus a Find/Replace submode)
- **Inspection**: Metadata (ffprobe output), Media Player (in-app playback)

## Architecture

There are two concurrent processing architectures in this app. Knowing which one a feature uses is essential before making changes.

### 1. Swift-Python IPC Bridge (split, separate, merge)

The older pattern. Used for any mode where ffmpeg does the heavy lifting.

1. `PythonRunner` (Swift actor) spawns a Python subprocess, sends a JSON config blob via stdin, reads newline-delimited JSON events from stdout.
2. Each Python script (`Scripts/*.py`) reads the config from stdin, performs ffmpeg operations, emits structured event JSON lines back to Swift.
3. `ProcessingEvent.swift` (formerly `PythonEvent.swift`) parses these JSON lines into a Swift enum with cases: `start`, `progress`, `fileStart`, `fileComplete`, `fileError`, `segmentStart`, `segmentComplete`, `complete`, `error`. The same enum is now also emitted directly by native pipelines, which is why the type was renamed.
4. `ProcessButton.swift` orchestrates: calls `PythonRunner.runSplitter / runSeparator / runMerger` for video operations, `FileRenamer` for rename operations, routes events back to `AppState`.

When adding a new Python-backed mode, you touch: the Python script, `PythonRunner` (new run method + config struct), `ProcessButton` (new case in `startProcessing`), `ToolMode` enum, `AppState` (new settings), `ToolSettingsViewModel` (if the settings should persist), and a new settings view.

### 2. Native GIF Pipeline (GIF / APNG output)

The newer pattern. Pure Swift, no subprocess, no ffmpeg.

Entry point: `GifRenderer` (actor) exposes `render(config:onEvent:)`. It consumes a `GifRenderConfig` rather than a Python JSON payload, and emits the same `ProcessingEvent` values the UI already consumes.

Per-file pipeline stages:

1. **Probe**: `VideoFrameExtractor.probe(url:)` uses AVFoundation to read duration and natural video dimensions. Replaces ffprobe for the GIF path.
2. **Segment math**: `KeepSegmentCalculator.keepRanges(...)` applies trim bounds and cut segments and returns the source-timeline ranges to keep. Pure static function.
3. **Resolution**: `ResolutionCalculator.outputDimensions(spec:sourceWidth:sourceHeight:)` resolves `ResolutionSpec` (original / scalePercent / fixedWidth / custom) into concrete output dimensions. Pure static function. Preserves even dimensions via banker's rounding for parity with the legacy ffmpeg behavior.
4. **Overlay remap**: `KeepSegmentCalculator.mapToOutputTimeline(...)` remaps a source-timeline text overlay window to the concat timeline; the renderer then divides by `speedMultiplier` to get final output-timeline positions.
5. **Extract**: `VideoFrameExtractor.extractFrames(url:keepRanges:frameRate:speedMultiplier:targetWidth:targetHeight:onFrame:)` uses `AVAssetImageGenerator.images(for:)` with zero tolerances and `appliesPreferredTrackTransform = true`. Emits frames to a caller-supplied `@Sendable` async callback in output-index order via a sliding-window reorder buffer. Failed indices are tracked explicitly so the drain head skips past them in real time instead of buffering the whole stream.
6. **Compose**: `GifRenderer.composeAndAppend(...)` creates a sRGB RGBA-premultiplied CGContext at target dimensions, draws the decoded frame with high interpolation (non-uniform scale for custom aspect matches the legacy ffmpeg `scale=W:H` behavior), then applies `TextOverlayRenderer.draw(...)` if the overlay time window is active.
7. **Write**: `AnimatedImageWriter` (actor) wraps `CGImageDestination` with an incremental `beginWriting` → `appendFrame` → `finalize` API. Uses `kCGImagePropertyGIFUnclampedDelayTime` / `kCGImagePropertyAPNGUnclampedDelayTime` so fps > 50 is respected (the non-unclamped variant is clamped to 0.02s minimum by most viewers).

WebP output is deliberately unsupported. macOS ImageIO has no WebP encoder on macOS 26. If WebP comes back someday, it means either a system framework added an encoder or we shipped a third-party one.

Native palette and dithering for GIF are not implemented. `AnimatedImageWriter.swift` contains a large `// MARK: - Future Work` comment block outlining how to restore those controls (median-cut quantization + Floyd-Steinberg dithering) if needed. ImageIO's internal quantizer is used instead.

All service types in the GIF subsystem are Swift actors (`GifRenderer`, `VideoFrameExtractor`, `AnimatedImageWriter`) even when they hold no mutable state. This matches the existing service convention (`PythonRunner`, `VideoProber`, `FileRenamer`) and costs little. Pure math helpers (`KeepSegmentCalculator`, `ResolutionCalculator`, `ColorParser`, `FontResolver`, `TextOverlayRenderer`) are enums used as namespaces for static functions and are safe to call from anywhere.

### State Management

- `AppState` is an `@Observable @MainActor` class injected via SwiftUI's `@Environment`. It holds UI state, per-video transient state (trim/cuts/overlay), and the video file list.
- `ToolSettingsViewModel` holds user-preference settings backed by SwiftData persistence. This is where GIF output format, resolution, frame rate, speed, and loop settings live.
- Views access both via `@Environment(...)` and use `@Bindable var state = appState` / `@Bindable var settings = toolSettings` for two-way bindings.
- No Combine, no ObservableObject — uses the Swift 5.9+ `@Observable` macro throughout.

### Key Services

- **`PythonRunner`** (actor, `Services/PythonRunner.swift`): Finds Python binary (UserDefaults override, then miniforge/miniconda/anaconda/homebrew/system paths), finds scripts (UserDefaults override, then app bundle, then fallback paths), manages subprocess lifecycle. Has methods for `runSplitter`, `runSeparator`, `runMerger`. The prior `runGifConverter` and its `Script.gif` enum case were removed when the GIF path went native.
- **`VideoProber`** (actor, `Services/VideoProber.swift`): Wraps `ffprobe` to extract `VideoMetadata` structs. Auto-discovers ffprobe at `/usr/local/bin`, `/opt/homebrew/bin`, or `/usr/bin`. Still used by all modes except GIF; GIF uses `VideoFrameExtractor.probe(url:)` natively.
- **`FileRenamer`** (actor, `Services/FileRenamer.swift`): Two-pass rename (original -> temp -> final) to avoid rename chain collisions. Pure Swift, no Python dependency.
- **`GifRenderer`** (actor, `Services/GifRenderer.swift`): Top-level orchestrator for the native GIF pipeline. See the Native GIF Pipeline section above.
- **`Services/Gif/*`**: Supporting types for the GIF pipeline. `KeepSegmentCalculator`, `ResolutionCalculator`, `ColorParser`, `FontResolver` are pure static namespaces. `VideoFrameExtractor`, `AnimatedImageWriter` are actors. `TextOverlayRenderer` is a pure static namespace that draws into a caller-supplied CGContext using a standard bottom-left-origin coordinate contract.

### Python Scripts

Three bundled scripts in `VideoTools/Scripts/`:
- `video_splitter_batch.py` — splits videos into segments using ffmpeg, supports VideoToolbox hardware acceleration
- `video_audio_separator_batch.py` — extracts video and audio streams separately
- `video_merger.py` — concatenates multiple videos

The legacy `video_to_gif.py` was removed when the native GIF pipeline landed.

All surviving scripts share the same IPC pattern: read JSON config from stdin, emit JSON event lines to stdout. They use `ProcessPoolExecutor` for parallel segment processing.

## Runtime Dependencies

- **Python 3** with ffmpeg accessible on PATH (required for split, separate, merge)
- **ffmpeg / ffprobe** (installed via Homebrew: `brew install ffmpeg`)
- Python path and scripts path are configurable in the app's Settings window (stored in `UserDefaults` as `pythonPath` and `scriptsPath`)
- The GIF path has no external runtime dependencies; AVFoundation and ImageIO ship with macOS.

## Project Conventions

- Service types (`PythonRunner`, `VideoProber`, `FileRenamer`, `GifRenderer`, `VideoFrameExtractor`, `AnimatedImageWriter`) are Swift actors for thread safety.
- Pure-math helpers in the GIF subsystem are `enum` namespaces with static functions. No unnecessary allocation.
- Models are value types (structs/enums) in `Models/`. `AppState` and `ToolSettingsViewModel` are the sole reference-type state containers.
- All types crossing actor boundaries are `Sendable` or `@unchecked Sendable` where the underlying type is immutable-after-creation (e.g. `CGImage`).
- The app has no test target currently; each GIF subsystem file contains a `#if DEBUG` validation harness (`FooTests.runAll()` returning `(passed, failed, failures)`) that exercises pure-logic helpers. Async actor tests use a thread-safe `ResultHolder` class with `NSLock` and a `DispatchSemaphore` to bridge back to the synchronous `runAll` contract.
- Entitlements file is empty (no sandbox) — the app needs direct filesystem and subprocess access.
- Python scripts use `sys.stdout.reconfigure(line_buffering=True)` for real-time event streaming.
- **No em-dashes anywhere** (project-wide author preference). Use hyphens, commas, or sentence splits.
- **No colons in bullet points.** Write bullets as complete sentences.

## Claude Code Agents

Four custom agents are defined in `.claude/agents/`:
- **xcode-builder-agent**: Must be used for all build operations (handles miniforge PATH contamination)
- **principal-swift-engineer**: For critical Swift implementations requiring production-quality code
- **code-review-agent**: Post-implementation review with CRITICAL/HIGH/MEDIUM/LOW priority classification
- **scrum-master**: Work package decomposition and task management
