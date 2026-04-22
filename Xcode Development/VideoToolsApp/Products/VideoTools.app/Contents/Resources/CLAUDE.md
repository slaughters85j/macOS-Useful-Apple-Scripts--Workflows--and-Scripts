# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**CRITICAL**: Never run bare `xcodebuild` or `swift build` directly. Miniforge3 contaminates the PATH with its own linker, causing cryptic build failures. Always use the clean build wrapper:

```bash
/Users/system-backup/bin/xcodebuild-clean -scheme VideoTools -destination 'platform=macOS' build
```

The Xcode project file is at the repo root: `VideoTools.xcodeproj`. There is no SPM Package.swift — this is a pure Xcode project.

## Project Overview

VideoTools is a **macOS-only SwiftUI app** (deployment target: macOS 26.0, Swift 6.0, bundle ID: `com.UBSAnalytics.VideoTools`) that provides a GUI for batch video processing operations. It delegates heavy video work to **bundled Python scripts** that call `ffmpeg`/`ffprobe` under the hood.

### Tool Modes

The app has six modes organized into three groups:

- **Video Processing**: Split (segment videos by duration/count), Separate A/V (extract video+audio streams), GIF (convert video to animated GIF)
- **File Management**: Rename Videos, Rename Photos (batch rename files using folder-name prefix with collision detection)
- **Inspection**: Metadata (view detailed ffprobe output)

### Architecture: Swift-Python IPC Bridge

The central architectural pattern is a **JSON-over-stdin/stdout IPC protocol** between Swift and Python:

1. `PythonRunner` (Swift actor) spawns a Python subprocess, sends a JSON config blob via stdin, then reads newline-delimited JSON events from stdout.
2. Each Python script (`Scripts/*.py`) reads the config from stdin, performs ffmpeg operations, and emits structured `PythonEvent` JSON lines back to Swift.
3. `PythonEvent.swift` parses these JSON lines into a Swift enum with cases: `start`, `progress`, `fileStart`, `fileComplete`, `fileError`, `segmentStart`, `segmentComplete`, `complete`, `error`.
4. `ProcessButton.swift` orchestrates processing: it calls `PythonRunner` for video operations or `FileRenamer` for rename operations, routing events back to `AppState`.

**When adding a new video processing mode**, you need to touch: the Python script, `PythonRunner` (new run method + config struct), `ProcessButton` (new case in `startProcessing`), `ToolMode` enum, `AppState` (new settings), and a new settings view.

### State Management

- `AppState` is an `@Observable @MainActor` class injected via SwiftUI's `@Environment`. It holds all UI state, settings for every mode, and the video file list.
- Views access it via `@Environment(AppState.self)` and use `@Bindable var state = appState` for two-way bindings.
- No Combine, no ObservableObject — uses the Swift 5.9+ `@Observable` macro throughout.

### Key Services

- **`PythonRunner`** (actor): Finds Python binary (checks UserDefaults override, then miniforge/miniconda/anaconda/homebrew/system paths), finds scripts (checks UserDefaults override, then app bundle, then fallback paths), manages subprocess lifecycle.
- **`VideoProber`** (actor): Wraps `ffprobe` to extract `VideoMetadata` structs. Auto-discovers ffprobe at `/usr/local/bin`, `/opt/homebrew/bin`, or `/usr/bin`.
- **`FileRenamer`** (actor): Two-pass rename (original -> temp -> final) to avoid rename chain collisions. Pure Swift, no Python dependency.

### Python Scripts

Three bundled scripts in `VideoTools/Scripts/`:
- `video_splitter_batch.py` — splits videos into segments using ffmpeg, supports VideoToolbox hardware acceleration
- `video_audio_separator_batch.py` — extracts video and audio streams separately
- `video_to_gif.py` — converts video to GIF with palette generation, trimming, dithering, speed control

All scripts share the same IPC pattern: read JSON config from stdin, emit JSON event lines to stdout. They use `ProcessPoolExecutor` for parallel segment processing.

## Runtime Dependencies

- **Python 3** with ffmpeg accessible on PATH
- **ffmpeg / ffprobe** (installed via Homebrew: `brew install ffmpeg`)
- Python path and scripts path are configurable in the app's Settings window (stored in `UserDefaults` as `pythonPath` and `scriptsPath`)

## Project Conventions

- All service types (`PythonRunner`, `VideoProber`, `FileRenamer`) are Swift actors for thread safety.
- Models are value types (structs/enums) in `Models/VideoModels.swift`. `AppState` is the sole reference-type state container.
- The app has no test target currently.
- Entitlements file is empty (no sandbox) — the app needs direct filesystem and subprocess access.
- Python scripts use `sys.stdout.reconfigure(line_buffering=True)` for real-time event streaming.

## Claude Code Agents

Four custom agents are defined in `.claude/agents/`:
- **xcode-builder-agent**: Must be used for all build operations (handles miniforge PATH contamination)
- **principal-swift-engineer**: For critical Swift implementations requiring production-quality code
- **code-review-agent**: Post-implementation review with CRITICAL/HIGH/MEDIUM/LOW priority classification
- **scrum-master**: Work package decomposition and task management
