# TODO

Open items from the native GIF and splitter migrations and related cleanup. Ordered roughly by priority; none is blocking the app from running.

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
- [ ] Time the splitter export end-to-end. Confirm the Python-startup dead-time is gone (first output file should appear within ~200 ms of clicking Process, not ~3 s).

## Test infrastructure

- [ ] The `#if DEBUG` `FooTests.runAll()` validation harnesses inside each GIF subsystem file are not yet wired to a proper XCTest target. They can be invoked manually from a debug entry point. Adding an XCTest target would let CI (when there is one) catch regressions.

## Possible follow-ons in other subsystems

- [x] Native replacement of `video_splitter_batch.py` (completed; see `Services/VideoSplitter.swift` and `Services/Split/*`).
- [ ] Native replacement of `video_audio_separator_batch.py`. Likely built on `AVAssetReader` + `AVAssetWriter` (audio-only), reusing the retiming helpers in `SegmentReencodeExporter` as a template. Not scoped to the current work package.
- [ ] Native replacement of `video_merger.py`. Concatenation via `AVMutableComposition` + `AVAssetExportSession` is the obvious path. The existing `MergerConfig` type already models the knobs. Not scoped to the current work package.

## Splitter follow-ups

- [ ] Cancel-button wiring for native pipelines. Pressing Cancel today calls `PythonRunner.cancel()`, which is a no-op for the native GIF and splitter paths (no subprocess to terminate). Native paths already check `Task.checkCancellation()` at every await point; they just need the outer `Task` reference held by `ProcessButton` so `.cancel()` can be called on it. Applies equally to the GIF path and now the split path.
- [ ] Consider exposing an output-resolution control on the splitter re-encode path. Not present today; `ResolutionCalculator` from the GIF subsystem is directly reusable if we add it.
- [ ] Honest per-codec quality slider. HEVC's `AVVideoQualityKey` is true constant-quality; H.264's mapping is a linear scaling of source bitrate with a 100 kbps floor. Revisit the H.264 curve if users complain that low-slider values still produce large files on high-bitrate source material.
