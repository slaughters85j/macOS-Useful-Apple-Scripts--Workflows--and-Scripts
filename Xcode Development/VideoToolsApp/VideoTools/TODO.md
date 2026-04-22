# TODO

Open items from the native GIF pipeline migration and related cleanup. Ordered roughly by priority; none is blocking the app from running.

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

- [ ] End-to-end visual and size comparison. Render a handful of representative videos (short clip, long clip, with cuts, with text overlay, with speed multiplier, at several resolutions) through both the legacy Python pipeline (git checkout prior to the native migration) and the current native pipeline. Compare output dimensions, frame counts, file sizes, and visual quality. Document any differences worth noting.

## Test infrastructure

- [ ] The `#if DEBUG` `FooTests.runAll()` validation harnesses inside each GIF subsystem file are not yet wired to a proper XCTest target. They can be invoked manually from a debug entry point. Adding an XCTest target would let CI (when there is one) catch regressions.

## Possible follow-ons in other subsystems

- [ ] Native replacement of `video_splitter_batch.py`, `video_audio_separator_batch.py`, and `video_merger.py` with AVFoundation-based pipelines. The GIF migration established the architectural pattern (Swift actor orchestrator, pure-math helpers, `ProcessingEvent` callback, `ToolSettingsViewModel` persistence). Each of the three remaining scripts is a candidate for the same treatment. Not scoped to the current work package.
