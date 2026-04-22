# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**CRITICAL**: Never run bare `xcodebuild` or `swift build` directly. Miniforge3 contaminates the PATH with its own linker, causing cryptic build failures. Always use the clean build wrapper:

```bash
/Users/system-backup/bin/xcodebuild-clean -scheme VideoTools -destination 'platform=macOS' build
```

The Xcode project file is at the repo root: `VideoTools.xcodeproj`. There is no SPM Package.swift — this is a pure Xcode project.

## Project Overview

VideoTools is a **macOS-only SwiftUI app** (deployment target: macOS 26.0, Swift 6.0, bundle ID: `com.UBSAnalytics.VideoTools`) that provides a GUI for batch video processing operations. It is a **hybrid native-plus-Python app**: the GIF, splitter, and merger pipelines are fully native (AVFoundation + ImageIO), while Separate A/V is the only remaining mode that delegates to a bundled Python script calling `ffmpeg` / `ffprobe`.

The native migration is nearly complete — Separate A/V is the sole remaining Python-backed mode. Any new feature should prefer native Swift unless there is a compelling reason (e.g. a third-party codec ffmpeg handles and AVFoundation does not) to stay on the Python path.

### Tool Modes

Modes are declared in `ToolMode` and routed by `ContentView` and `ProcessButton`.

- **Video Processing (Python-backed)**: Separate A/V
- **Video Processing (native)**: Split, Merge, GIF (GIF or APNG output)
- **File Management**: Rename Videos, Rename Photos (batch rename using folder-name prefix with collision detection, plus a Find/Replace submode)
- **Inspection**: Metadata (ffprobe output), Media Player (in-app playback)

## Architecture

There are two concurrent processing architectures in this app. Knowing which one a feature uses is essential before making changes.

### 1. Swift-Python IPC Bridge (separate A/V only)

The older pattern. Only `Separate A/V` still uses it; the splitter and merger have been ported to native AVFoundation.

1. `PythonRunner` (Swift actor) spawns a Python subprocess, sends a JSON config blob via stdin, reads newline-delimited JSON events from stdout.
2. The surviving Python script (`Scripts/video_audio_separator_batch.py`) reads the config from stdin, performs ffmpeg operations, emits structured event JSON lines back to Swift.
3. `ProcessingEvent.swift` (formerly `PythonEvent.swift`) parses these JSON lines into a Swift enum with cases: `start`, `progress`, `fileStart`, `fileComplete`, `fileError`, `segmentStart`, `segmentComplete`, `complete`, `error`. The same enum is also emitted directly by native pipelines, which is why the type was renamed.
4. `ProcessButton.swift` orchestrates: calls `PythonRunner.runSeparator` for separation, native orchestrators (`GifRenderer`, `VideoSplitter`, `VideoMerger`) for the rest, `FileRenamer` for rename operations, routes events back to `AppState`.

When Separate A/V is eventually ported, `PythonRunner` can be deleted entirely. Until then, it exists solely for this one mode.

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

### 3. Native Splitter Pipeline (Split mode)

The newest native pipeline. Pure Swift, no subprocess, no ffmpeg.

Entry point: `VideoSplitter` (actor) exposes `split(config:onEvent:)`. It consumes a `SplitConfig` and emits the same `ProcessingEvent` values the UI already consumes.

Per-file pipeline stages:

1. **Probe**: `AVURLAsset.load(.duration)` + `AVAssetTrack.load(...)` collects duration, nominal frame rate, preferred transform, estimated data rate, and natural size. No ffprobe.
2. **Segment planning**: `SplitSegmentCalculator.segmentRanges(...)` converts the user's `SplitMethod` + `splitValue` into a list of non-overlapping, duration-covering `CMTimeRange`s. Pure static function. Handles `.duration` (equal slicing with short tail), `.segments` (equal count), and `.reencodeOnly` (single full-duration segment) uniformly.
3. **Output folder resolution**: Creates `<stem>_parts/` or uses the source's parent directory, per `OutputFolderMode`. Output filenames are `<stem>_partNNN.<ext>` where extension is preserved from the source.
4. **Route decision**: `codec == .copy` with no fps override routes to passthrough; anything else (or an fps override, which forces re-encode because passthrough cannot change frame rate) routes to re-encode.
5. **Encoder settings**: `SplitEncoderSettings.videoOutputSettings(...)` builds the `AVAssetWriterInput` dict once per file. HEVC + quality uses `AVVideoQualityKey` (true constant-quality VT encoding). H.264 + quality uses `AVVideoAverageBitRateKey` scaled from source bitrate (slider/50 multiplier with 100 kbps floor). Match-bitrate uses source bitrate directly on either codec.
6. **Segment dispatch**: A `TaskGroup` runs up to `config.parallelJobs` segment exports concurrently per file (honored verbatim; the VideoToolbox encoder queue is the OS's problem). Each segment is routed to either `SegmentPassthroughExporter` or `SegmentReencodeExporter`.
7. **Passthrough segments**: `SegmentPassthroughExporter` wraps `AVAssetExportSession` with `AVAssetExportPresetPassthrough` and `timeRange`. Uses the modern `export(to:as:)` async API. Keyframe-snaps segment boundaries identically to ffmpeg `-c copy`.
8. **Re-encode segments**: `SegmentReencodeExporter` wraps a paired `AVAssetReader` + `AVAssetWriter`. Video is decoded to `420YpCbCr8BiPlanarVideoRange` (zero-copy from VT hardware decode) and re-encoded through VideoToolbox. Audio is passed through untouched. Sample PTS is retimed segment-relative via `CMSampleBufferCreateCopyWithNewTiming`. When the target fps differs from source, a nearest-past-source-frame resampler emits synthesized output frames at the target cadence.
9. **Finalize**: reader and writer status are checked after EOF; failures throw `ExportError` and do not ship a partial file.

Re-encode preserves the source track's `preferredTransform` on the writer input so rotated and portrait sources stay oriented correctly without actually rotating pixels.

Supporting types live in `Services/Split/`:
- `SplitSegmentCalculator`, `SplitEncoderSettings` — pure static namespaces.
- `SegmentPassthroughExporter`, `SegmentReencodeExporter` — actors.

The `SplitConfig` model type lives in `Models/SplitConfig.swift` alongside the `AppState.buildSplitConfig()` builder extension (mirrors `GifRenderConfig` and `buildGifRenderConfig()`).

### 4. Native Merger Pipeline (Merge mode)

Most recent native pipeline. Pure Swift, no subprocess, no ffmpeg.

Entry point: `VideoMerger` (actor) exposes `merge(config:onEvent:)`. Consumes a `MergeConfig` and emits `ProcessingEvent` values. Unlike the splitter (which produces N output files from N inputs), the merger produces **one** output file from N inputs, so the event stream reports a single synthetic "merge" file with per-input `segmentStart/segmentComplete` events driving the probe-phase progress.

Per-batch pipeline stages:

1. **Probe** every input via `AVURLAsset.load(.duration)` + `AVAssetTrack.load(...)`. Collects duration, display size (post preferredTransform), nominal fps, codec FourCC, estimated data rate, and whether an audio track is present. Result populated into an `InputVideoInfo` struct used by downstream stages.
2. **Compatibility check** (copy codec only): `MergeCompatibilityChecker.copyModeError(inputs:)` returns `nil` or a descriptive error. Tolerances match the legacy script: codec FourCC exact, dimensions within 2 px, fps within 0.5. On mismatch, the orchestrator surfaces the error via `fileError` and aborts without writing output.
3. **Build composition**: `CompositionBuilder.build(...)` assembles an `AVMutableComposition` by appending each input's video + audio tracks sequentially from time zero. Audio gaps are filled with `insertEmptyTimeRange` for inputs that lack audio. For re-encode, also produces an `AVMutableVideoComposition` with per-instruction layer transforms implementing letterbox (aspect-fit) or crop/fill (aspect-fill), both centered on the target canvas. Target canvas size is `max(displayWidth) × max(displayHeight)` across inputs, rounded to even numbers.
4. **Passthrough path** (codec=Copy): `MergePassthroughExporter` wraps `AVAssetExportSession(asset: composition, preset: Passthrough)` with the modern `export(to:as:)` async API. Matches ffmpeg concat-demuxer behavior.
5. **Re-encode path** (H.264 / HEVC): `MergeReencodeExporter` wraps `AVAssetReader(asset: composition)` with an `AVAssetReaderVideoCompositionOutput` carrying the layer transforms, plus an `AVAssetWriter` whose video input settings come from `SplitEncoderSettings.videoOutputSettings(...)` — the exact same builder the splitter uses. Audio is re-encoded to AAC (stereo, 48 kHz, 192 kbps) via an `AVAssetReaderAudioMixOutput` decoding to LPCM and a writer input with AAC settings. Matches the Python `aformat`/`aresample`/AAC chain.
6. **Finalize**: reader and writer status checked; any failure throws a typed `ExportError`.

Notable simplifications versus the splitter's re-encode path: no PTS offset retiming (composition timeline already starts at zero) and no custom fps resampler (`AVVideoComposition.frameDuration` handles target fps natively).

Supporting types live in `Services/Merge/`:
- `MergeCompatibilityChecker`, `CompositionBuilder` — pure static namespaces.
- `MergePassthroughExporter`, `MergeReencodeExporter` — actors.

The `MergeConfig` model type lives in `Models/MergeConfig.swift` alongside the `AppState.buildMergeConfig()` builder extension. The H.264 quality slider is anchored to `max(estimatedDataRate)` across inputs rather than a single source bitrate, since a merge by definition has N potential anchors.

Known forward-compatibility note: `CompositionBuilder.swift` uses the deprecated `AVMutableVideoComposition` class family (superseded in macOS 26 by `AVVideoComposition.Configuration`). Deprecation is acknowledged in-file; migration is tracked in TODO.md.

### State Management

- `AppState` is an `@Observable @MainActor` class injected via SwiftUI's `@Environment`. It holds UI state, per-video transient state (trim/cuts/overlay), and the video file list.
- `ToolSettingsViewModel` holds user-preference settings backed by SwiftData persistence. This is where GIF output format, resolution, frame rate, speed, and loop settings live.
- Views access both via `@Environment(...)` and use `@Bindable var state = appState` / `@Bindable var settings = toolSettings` for two-way bindings.
- No Combine, no ObservableObject — uses the Swift 5.9+ `@Observable` macro throughout.

### Key Services

- **`PythonRunner`** (actor, `Services/PythonRunner.swift`): Finds Python binary (UserDefaults override, then miniforge/miniconda/anaconda/homebrew/system paths), finds scripts (UserDefaults override, then app bundle, then fallback paths), manages subprocess lifecycle. Has a single method `runSeparator`. The prior `runGifConverter`, `runSplitter`, `runMerger`, and their corresponding `Script.gif` / `Script.splitter` / `Script.merger` enum cases were removed when those paths went native.
- **`VideoProber`** (actor, `Services/VideoProber.swift`): Wraps `ffprobe` to extract `VideoMetadata` structs. Auto-discovers ffprobe at `/usr/local/bin`, `/opt/homebrew/bin`, or `/usr/bin`. Still used by Separate A/V and the Metadata inspector; GIF, Split, and Merge probe sources natively via `AVURLAsset`.
- **`FileRenamer`** (actor, `Services/FileRenamer.swift`): Two-pass rename (original -> temp -> final) to avoid rename chain collisions. Pure Swift, no Python dependency.
- **`GifRenderer`** (actor, `Services/GifRenderer.swift`): Top-level orchestrator for the native GIF pipeline. See the Native GIF Pipeline section above.
- **`VideoSplitter`** (actor, `Services/VideoSplitter.swift`): Top-level orchestrator for the native splitter. See the Native Splitter Pipeline section above.
- **`VideoMerger`** (actor, `Services/VideoMerger.swift`): Top-level orchestrator for the native merger. See the Native Merger Pipeline section above.
- **`Services/Gif/*`**: Supporting types for the GIF pipeline. `KeepSegmentCalculator`, `ResolutionCalculator`, `ColorParser`, `FontResolver` are pure static namespaces. `VideoFrameExtractor`, `AnimatedImageWriter` are actors. `TextOverlayRenderer` is a pure static namespace that draws into a caller-supplied CGContext using a standard bottom-left-origin coordinate contract.
- **`Services/Split/*`**: Supporting types for the splitter pipeline. `SplitSegmentCalculator`, `SplitEncoderSettings` are pure static namespaces. `SegmentPassthroughExporter` and `SegmentReencodeExporter` are actors wrapping `AVAssetExportSession` and `AVAssetReader`/`AVAssetWriter` respectively.
- **`Services/Merge/*`**: Supporting types for the merger pipeline. `MergeCompatibilityChecker`, `CompositionBuilder` are pure static namespaces. `MergePassthroughExporter` and `MergeReencodeExporter` are actors wrapping `AVAssetExportSession` (on a composition) and `AVAssetReader`/`AVAssetWriter` respectively. `SplitEncoderSettings.videoOutputSettings` is reused directly — codec/quality mapping is identical across splitter and merger.

### Python Scripts

One bundled script in `VideoTools/Scripts/`:
- `video_audio_separator_batch.py` — extracts video and audio streams separately

The legacy `video_to_gif.py` was removed when the native GIF pipeline landed. `video_splitter_batch.py` was removed when the native splitter landed. `video_merger.py` was removed when the native merger landed. When Separate A/V eventually goes native, the Scripts directory and all Python dependencies can be deleted entirely.

The surviving script shares the same IPC pattern established by its predecessors: read JSON config from stdin, emit JSON event lines to stdout. It uses `ProcessPoolExecutor` for parallel per-file processing.

## Runtime Dependencies

- **Python 3** with ffmpeg accessible on PATH (required for Separate A/V only)
- **ffmpeg / ffprobe** (installed via Homebrew: `brew install ffmpeg`)
- Python path and scripts path are configurable in the app's Settings window (stored in `UserDefaults` as `pythonPath` and `scriptsPath`)
- The GIF, Split, and Merge paths have no external runtime dependencies; AVFoundation, CoreMedia, and ImageIO ship with macOS.

## Project Conventions

- Service types (`PythonRunner`, `VideoProber`, `FileRenamer`, `GifRenderer`, `VideoFrameExtractor`, `AnimatedImageWriter`, `VideoSplitter`, `SegmentPassthroughExporter`, `SegmentReencodeExporter`) are Swift actors for thread safety.
- Pure-math helpers in the GIF and Split subsystems are `enum` namespaces with static functions. No unnecessary allocation.
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
