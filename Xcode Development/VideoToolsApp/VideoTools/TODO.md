# TODO

Open items from the native migration (GIF, splitter, merger, separator, metadata). The app is now fully native — no Python, no ffmpeg, no ffprobe. Items below are polish, validation, and follow-ups; none blocks the app from running.

## Small cleanup candidates (deferred)

These were flagged during the GIF migration, verified by `rg` to be effectively dead or single-consumer, and deliberately kept for later:

- [ ] `CodableColor.ffmpegHex` and `CodableColor.pillowHex` (in `Models/GifModels.swift`). No direct call sites after removal of `TextOverlayConfig`. Only referenced in a `ColorParser` doc comment. Safe to remove when the new text-overlay pipeline is confirmed to never need hex serialization again.
- [ ] `GifSettings` legacy per-file struct (in `Models/GifModels.swift`). Still referenced by `VideoFile.gifSettings`. Remove together with that per-file setting if the app moves to centralized GIF settings only.

## GIF subsystem file size

Two files exceed the 450-line preferred soft ceiling because their in-file DEBUG test harnesses are substantial. The validation tests could be moved to sibling `*Tests.swift` files if we adopt that pattern across the GIF subsystem:

- [ ] `Services/Gif/VideoFrameExtractor.swift` (~525 lines)
- [ ] `Services/Gif/AnimatedImageWriter.swift` (~500+ lines)
- [ ] `Services/GifRenderer.swift` (~510 lines)

Not urgent. The other GIF subsystem files are already under the ceiling.

## Future feature (explicitly scoped out)

- [ ] Native GIF palette generation and dithering. The current pipeline delegates GIF quantization entirely to ImageIO, which has no exposed tunables. `Services/Gif/AnimatedImageWriter.swift` contains a large `// MARK: - Future Work` comment block describing the implementation roadmap (median-cut + Floyd-Steinberg, or Metal-backed Bayer). The legacy Python pipeline's Colors and Dithering controls were removed from the UI because they had nothing to bind to.

## Validation (to close out the migration)

- [ ] End-to-end visual and size comparison (GIF). Render a handful of representative videos (short clip, long clip, with cuts, with text overlay, with speed multiplier, at several resolutions) through both the legacy Python pipeline (git checkout prior to the native migration) and the current native pipeline. Compare output dimensions, frame counts, file sizes, and visual quality. Document any differences worth noting.
- [ ] End-to-end visual and size comparison (splitter). For each split mode (duration, segments, reencode-only) and each codec (copy, H.264, HEVC) plus the match-bitrate and quality-slider variants, run the same clip through the native splitter and the archived Python version. Verify segment durations (within one keyframe interval for copy, within one frame for re-encode), audio sync, and file-size ballpark. Especially confirm the HEVC constant-quality and H.264 bitrate mappings feel sensible on the quality slider.
- [ ] End-to-end visual and size comparison (merger). Three matching 720p H.264 clips with codec=Copy should produce a seamless concat. Two clips at different aspects (16:9 + 9:16) at each aspect mode (letterbox, crop/fill) should render with correct black-bar placement or centered crop. An input with audio plus an input without audio should produce a merged output with silence in the no-audio region and no A/V drift. Copy mode with mismatched resolutions should fail fast with the guidance message. Target fps override (source 30, target 24) should yield 24 fps in ffprobe output. Custom output directory picker should land the file where expected.

### Merger smoke tests — focused subset to run first

Three scenarios that cover where the native merger could quietly diverge from the Python path. Run these before the broader matrix above.

- [ ] **Letterbox with mixed aspects**: one 16:9 clip + one 9:16 clip, codec=H.264, aspect=Letterbox. Verify the portrait clip lands centered with black bars on left and right (not cropped), and the landscape clip fills without bars.
- [ ] **Audio-gap handling**: one clip with audio + one clip without, any codec. Verify the audio-less region produces silence (not the previous clip's audio bleeding into it), and the next clip's audio starts at the right PTS (no early start, no drift).
- [ ] **Copy-mode rejection**: three clips with deliberately mismatched resolutions (e.g. 1920x1080 + 1280x720 + 854x480), codec=Copy. Verify it fails fast with the guidance error string, produces no output file, and the batch ends cleanly (UI returns to idle, not stuck).
- [ ] End-to-end comparison (separator). Single H.264 file should produce `<stem>_separated/<stem>_video.mp4` (no audio, passthrough) + `<stem>_audio.wav`. HEVC `.mov` source should produce `<stem>_video.mov` (extension preserved — behavioral improvement over the Python path, which always emitted mp4). Per-file 44.1 kHz sample-rate override should show up in afinfo / ffprobe of the resulting WAV. Sources with no audio track should produce only the video output and no error.
- [ ] End-to-end metadata parity (best-effort native prober). Compare the rewritten `VideoProber` against the archived ffprobe output for: H.264 8-bit, HEVC 10-bit HDR, ProRes, MP3/AAC audio containers. Pixel Format / Color Space / Bit Depth should populate for all four; if any come back nil, decide whether to extend the `CMFormatDescription` extension extractor or accept the "—" display.
- [ ] Time all four export pipelines end-to-end. Confirm the Python-startup dead-time is gone across the board (first output file should appear within ~200 ms of clicking Process for all modes, not ~3 s).
- [ ] Runtime-dependency removal check. Uninstall ffmpeg and ffprobe (`brew uninstall ffmpeg`), remove Python from PATH. Launch the app. Every mode should still work. Verify `Contents/Resources/` in the built bundle contains zero `.py` files.

### Separator smoke tests — focused subset

- [ ] **Video-only extension preservation**: run the separator on a `.mov` file. Verify the video output is `<stem>_video.mov` (not `.mp4`) and plays without audio.
- [ ] **Audio sample-rate override**: override a single file to 44.1 kHz. Run the separator. Verify the resulting `.wav` is 44.1 kHz with `afinfo` or QuickTime inspector.
- [ ] **Parallel jobs**: add 4+ files, set Parallel Jobs = 4. Confirm they process concurrently (progress strip moves on multiple files simultaneously).
- [ ] **Missing audio track**: file with no audio should produce only the video output (no `.wav`), no error, and `fileComplete` still fires with success.

### Cancellation smoke tests

- [ ] Cancel during a long re-encode (HEVC split of a large file or merge re-encode). UI should return to idle within 1-2 seconds; no orphaned partial output files left behind.
- [ ] Cancel during a separator batch of many files. Currently-processing file's outputs should be discarded; batch should terminate cleanly.

## Test infrastructure

- [ ] The `#if DEBUG` `FooTests.runAll()` validation harnesses inside each GIF subsystem file are not yet wired to a proper XCTest target. They can be invoked manually from a debug entry point. Adding an XCTest target would let CI (when there is one) catch regressions.

## Native migration history

- [x] Native replacement of `video_to_gif.py` (GIF/APNG pipeline; see `Services/GifRenderer.swift` and `Services/Gif/*`).
- [x] Native replacement of `video_splitter_batch.py` (see `Services/VideoSplitter.swift` and `Services/Split/*`).
- [x] Native replacement of `video_merger.py` (see `Services/VideoMerger.swift` and `Services/Merge/*`).
- [x] Native replacement of `video_audio_separator_batch.py` (see `Services/VideoSeparator.swift` and `Services/Separate/*`).
- [x] Native replacement of ffprobe (rewrote `Services/VideoProber.swift` on top of `AVURLAsset` + `CMFormatDescription` extensions).
- [x] Cancel-button wiring for native pipelines (`AppState.currentTask` + `ProcessButton` task tracking).
- [x] Deleted `PythonRunner.swift`, the `Scripts/` directory, and all Python/ffmpeg runtime dependencies.

## Cross-cutting follow-ups

- [ ] Consider exposing an output-resolution control on the splitter re-encode path. Not present today; `ResolutionCalculator` from the GIF subsystem is directly reusable if we add it. The merger already has an implicit target canvas (`max × max`); a similar user-facing override could apply there too.
- [ ] Honest per-codec quality slider. HEVC's `AVVideoQualityKey` is true constant-quality; H.264's mapping is a linear scaling of source bitrate with a 100 kbps floor. The merger anchors the H.264 mapping to `max(estimatedDataRate)` across inputs. Revisit the curves if users complain that low-slider values still produce large files on high-bitrate source material.
- [ ] Migrate `CompositionBuilder.swift` from the deprecated `AVMutableVideoComposition` / `AVMutableVideoCompositionInstruction` / `AVMutableVideoCompositionLayerInstruction` APIs to the new macOS 26 `AVVideoComposition.Configuration` / `AVVideoCompositionInstruction.Configuration` / `AVVideoCompositionLayerInstruction.Configuration` builders. The deprecated classes still work today; this is future-proofing. Six deprecation warnings come from this file alone.
- [ ] Consider extending `VideoProber`'s `CMFormatDescription` extension extractor for more codecs if the Pixel Format / Color Space / Bit Depth fields commonly show "—" on real user files. The current implementation is best-effort and covers H.264, HEVC, and ProRes cleanly.
- [ ] The `SettingsView` is now a placeholder. If future features (e.g. custom output directory defaults, color-management preferences, logging verbosity) need UI, this is the natural home. The stored `pythonPath` / `scriptsPath` UserDefaults keys are left untouched — harmless but no longer read.

## Python-era artifacts in the repo root

- [ ] The `Python/Photo & Video Management/` directory at the repo root still contains the source copies of the four Python scripts. These are the original standalone versions that predate the macOS app. Decide whether to keep them as historical reference (some users may run them directly from Finder) or remove them now that the app no longer depends on them.
