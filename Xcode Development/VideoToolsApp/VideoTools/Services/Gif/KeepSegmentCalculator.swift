import Foundation

// MARK: - TimeRange

/// A time range on some timeline, in seconds. `end > start` is an invariant.
///
/// Code Reuse Candidate: generic value type useful beyond GIF rendering.
/// If Split or Separate A/V gain trim/cut support, move this to a shared Models
/// location and reuse it rather than reinventing per-feature range types.
struct TimeRange: Sendable, Equatable {
    let start: Double
    let end: Double

    /// Duration of the range in seconds. Always positive because of the invariant.
    var duration: Double { end - start }
} // TimeRange

// MARK: - KeepSegmentCalculator

/// Pure segment math for GIF rendering.
///
/// Given a source duration, a trim window, and a set of cut segments to remove,
/// produce the list of ranges that should actually be emitted into the output.
/// Also provides overlay time remapping from the source timeline to the output timeline.
///
/// Everything here is a pure static function. No I/O, no state, no allocations
/// beyond the returned arrays. Call sites do not need to be actors.
enum KeepSegmentCalculator {

    // MARK: - Public API

    /// Compute the ranges of the SOURCE timeline that should be KEPT in the output,
    /// after applying the trim window and removing all cut segments.
    ///
    /// - Parameters:
    ///   - duration: Total source video duration in seconds.
    ///   - trimStart: Start of the trim window. Clamped into `[0, duration]`.
    ///   - trimEnd: End of the trim window. `nil` means use `duration`.
    ///   - cuts: Segments to REMOVE from the kept range. In source timeline.
    ///   - targetFPS: If positive, all times are snapped to the nearest frame
    ///                boundary for this fps. If zero or negative, no snapping.
    /// - Returns: Zero or more non-overlapping `TimeRange`s in source-timeline order.
    ///            Empty array means nothing survives the cut operations.
    static func keepRanges(
        duration: Double,
        trimStart: Double,
        trimEnd: Double?,
        cuts: [CutSegment],
        targetFPS: Double
    ) -> [TimeRange] {

        // Clamp the trim window to the valid source range
        let rawStart = max(0, trimStart)
        let rawEnd = min(duration, trimEnd ?? duration)
        guard rawEnd > rawStart else { return [] }

        // Snap trim bounds to frame boundaries (no-op if targetFPS <= 0)
        let snappedStart = snapToFrame(rawStart, fps: targetFPS)
        let snappedEnd = snapToFrame(rawEnd, fps: targetFPS)
        guard snappedEnd > snappedStart else { return [] }

        var ranges: [TimeRange] = [TimeRange(start: snappedStart, end: snappedEnd)]

        // Cuts must be applied in source-time order so splits accumulate predictably
        let sortedCuts = cuts.sorted { $0.startTime < $1.startTime }

        for cut in sortedCuts {
            let cutStart = snapToFrame(cut.startTime, fps: targetFPS)
            let cutEnd = snapToFrame(cut.endTime, fps: targetFPS)

            // Skip degenerate or inverted cuts rather than producing garbage
            guard cutEnd > cutStart else { continue }

            var newRanges: [TimeRange] = []
            for range in ranges {

                // Cut is entirely outside this range: keep the range unchanged
                if cutEnd <= range.start || cutStart >= range.end {
                    newRanges.append(range)
                    continue
                }

                // Cut overlaps the start of this range: keep only the tail
                if cutStart <= range.start && cutEnd < range.end {
                    newRanges.append(TimeRange(start: cutEnd, end: range.end))
                    continue
                }

                // Cut overlaps the end of this range: keep only the head
                if cutStart > range.start && cutEnd >= range.end {
                    newRanges.append(TimeRange(start: range.start, end: cutStart))
                    continue
                }

                // Cut lies strictly inside this range: split into two
                if cutStart > range.start && cutEnd < range.end {
                    newRanges.append(TimeRange(start: range.start, end: cutStart))
                    newRanges.append(TimeRange(start: cutEnd, end: range.end))
                    continue
                }

                // Otherwise the cut completely covers the range: drop it (fall through)
            }
            ranges = newRanges
        }

        return ranges
    } // keepRanges

    /// Map a start/end pair expressed in the SOURCE timeline to the OUTPUT timeline,
    /// given the set of kept ranges.
    ///
    /// Used to remap text overlay start/end times from the user's source-timeline
    /// perspective to the actual output-timeline positions after cuts are applied.
    ///
    /// - Returns: A `TimeRange` in OUTPUT timeline coordinates, or `nil` if the
    ///            source range doesn't intersect any kept range.
    static func mapToOutputTimeline(
        sourceStart: Double,
        sourceEnd: Double,
        keepRanges: [TimeRange]
    ) -> TimeRange? {

        guard sourceEnd > sourceStart else { return nil }

        // Walk the kept ranges in order, accumulating output time as we go
        var outputCursor: Double = 0
        var adjustedStart: Double? = nil
        var adjustedEnd: Double? = nil

        for range in keepRanges {
            let visibleStart = max(sourceStart, range.start)
            let visibleEnd = min(sourceEnd, range.end)

            if visibleStart < visibleEnd {
                let offsetInRange = visibleStart - range.start
                if adjustedStart == nil {
                    adjustedStart = outputCursor + offsetInRange
                }
                adjustedEnd = outputCursor + (visibleEnd - range.start)
            }

            outputCursor += range.duration
        }

        if let s = adjustedStart, let e = adjustedEnd, e > s {
            return TimeRange(start: s, end: e)
        }
        return nil
    } // mapToOutputTimeline

    /// Snap a time value to the nearest frame boundary for the given fps.
    /// Returns the input unchanged if `fps <= 0`.
    ///
    /// Code Reuse Candidate: useful anywhere frame-accurate cutting is needed.
    static func snapToFrame(_ time: Double, fps: Double) -> Double {
        guard fps > 0 else { return time }
        let frameDuration = 1.0 / fps
        let frameNumber = (time / frameDuration).rounded()
        return frameNumber * frameDuration
    } // snapToFrame
} // KeepSegmentCalculator

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `KeepSegmentCalculator`.
/// Call `KeepSegmentCalculatorTests.runAll()` from a scratch entry point under `#if DEBUG`.
enum KeepSegmentCalculatorTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition {
                passed += 1
            } else {
                failed.append(name)
            }
        } // check

        // MARK: snapToFrame tests

        check("snap with fps 0 returns input",
              KeepSegmentCalculator.snapToFrame(3.14, fps: 0) == 3.14)
        check("snap with fps -1 returns input",
              KeepSegmentCalculator.snapToFrame(3.14, fps: -1) == 3.14)

        check("snap 0.04 at 30fps snaps to frame 1",
              abs(KeepSegmentCalculator.snapToFrame(0.04, fps: 30) - (1.0 / 30.0)) < 1e-9)
        check("snap 0.05 at 30fps snaps to frame 2",
              abs(KeepSegmentCalculator.snapToFrame(0.05, fps: 30) - (2.0 / 30.0)) < 1e-9)
        check("snap 0 at 15fps returns 0",
              KeepSegmentCalculator.snapToFrame(0, fps: 15) == 0)

        // MARK: keepRanges tests, no cuts

        let noCut = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 0, trimEnd: nil, cuts: [], targetFPS: 0
        )
        check("no trim no cuts gives full range",
              noCut == [TimeRange(start: 0, end: 10)])

        let trimOnly = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 2, trimEnd: 8, cuts: [], targetFPS: 0
        )
        check("trim only gives trimmed range",
              trimOnly == [TimeRange(start: 2, end: 8)])

        let trimEndNil = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 3, trimEnd: nil, cuts: [], targetFPS: 0
        )
        check("trimEnd nil uses duration",
              trimEndNil == [TimeRange(start: 3, end: 10)])

        let trimNegative = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: -5, trimEnd: nil, cuts: [], targetFPS: 0
        )
        check("negative trimStart is clamped to 0",
              trimNegative == [TimeRange(start: 0, end: 10)])

        let trimPastEnd = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 0, trimEnd: 20, cuts: [], targetFPS: 0
        )
        check("trimEnd past duration is clamped",
              trimPastEnd == [TimeRange(start: 0, end: 10)])

        let emptyTrim = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 5, trimEnd: 5, cuts: [], targetFPS: 0
        )
        check("trimStart equal to trimEnd gives empty",
              emptyTrim.isEmpty)

        // MARK: keepRanges tests, single cut cases

        let cutMiddle = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 0, trimEnd: nil,
            cuts: [CutSegment(startTime: 3, endTime: 6)], targetFPS: 0
        )
        check("cut in middle splits into two ranges",
              cutMiddle == [TimeRange(start: 0, end: 3), TimeRange(start: 6, end: 10)])

        let cutOverStart = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 2, trimEnd: 8,
            cuts: [CutSegment(startTime: 0, endTime: 4)], targetFPS: 0
        )
        check("cut overlapping start truncates start",
              cutOverStart == [TimeRange(start: 4, end: 8)])

        let cutOverEnd = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 2, trimEnd: 8,
            cuts: [CutSegment(startTime: 6, endTime: 10)], targetFPS: 0
        )
        check("cut overlapping end truncates end",
              cutOverEnd == [TimeRange(start: 2, end: 6)])

        let cutCovers = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 2, trimEnd: 8,
            cuts: [CutSegment(startTime: 1, endTime: 9)], targetFPS: 0
        )
        check("cut covering whole range gives empty",
              cutCovers.isEmpty)

        let cutOutside = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 2, trimEnd: 8,
            cuts: [CutSegment(startTime: 9, endTime: 10)], targetFPS: 0
        )
        check("cut outside trim is ignored",
              cutOutside == [TimeRange(start: 2, end: 8)])

        let degenCut = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 0, trimEnd: nil,
            cuts: [CutSegment(startTime: 5, endTime: 5)], targetFPS: 0
        )
        check("degenerate cut (zero length) is ignored",
              degenCut == [TimeRange(start: 0, end: 10)])

        // MARK: keepRanges tests, multiple cuts

        let twoCuts = KeepSegmentCalculator.keepRanges(
            duration: 20, trimStart: 0, trimEnd: nil,
            cuts: [
                CutSegment(startTime: 3, endTime: 5),
                CutSegment(startTime: 10, endTime: 13)
            ],
            targetFPS: 0
        )
        check("two non-overlapping cuts produce three ranges",
              twoCuts == [
                TimeRange(start: 0, end: 3),
                TimeRange(start: 5, end: 10),
                TimeRange(start: 13, end: 20)
              ])

        let unsortedCuts = KeepSegmentCalculator.keepRanges(
            duration: 20, trimStart: 0, trimEnd: nil,
            cuts: [
                CutSegment(startTime: 10, endTime: 13),
                CutSegment(startTime: 3, endTime: 5)
            ],
            targetFPS: 0
        )
        check("cuts are sorted internally regardless of input order",
              unsortedCuts == twoCuts)

        // MARK: keepRanges with FPS snapping

        let snapped = KeepSegmentCalculator.keepRanges(
            duration: 10, trimStart: 0.04, trimEnd: 9.97,
            cuts: [], targetFPS: 30
        )
        // 0.04 at 30fps snaps to frame 1 (1/30 = 0.0333...)
        // 9.97 at 30fps snaps to round(9.97 * 30) = 299, so 299/30 = 9.9666...
        check("trim snapped to frame boundaries",
              snapped.count == 1 &&
              abs(snapped[0].start - (1.0 / 30.0)) < 1e-9 &&
              abs(snapped[0].end - (299.0 / 30.0)) < 1e-9)

        // MARK: mapToOutputTimeline tests

        let singleKeep = [TimeRange(start: 0, end: 10)]
        let mapSingle = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: 2, sourceEnd: 7, keepRanges: singleKeep
        )
        check("overlay in single kept range maps 1-to-1",
              mapSingle == TimeRange(start: 2, end: 7))

        let twoKeeps = [TimeRange(start: 0, end: 5), TimeRange(start: 10, end: 15)]
        // Overlay 2..12 in source. First 2..5 is visible (output 2..5 since cursor=0).
        // Cursor advances by duration of first kept range (5).
        // Second kept range 10..15: overlay intersects 10..12. adjustedEnd = 5 + (12-10) = 7.
        let mapSpanning = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: 2, sourceEnd: 12, keepRanges: twoKeeps
        )
        check("overlay spanning two kept ranges collapses the gap",
              mapSpanning == TimeRange(start: 2, end: 7))

        let mapMiss = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: 5, sourceEnd: 10,
            keepRanges: [TimeRange(start: 0, end: 4)]
        )
        check("overlay outside all kept ranges returns nil",
              mapMiss == nil)

        let mapPartialSecond = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: 12, sourceEnd: 14, keepRanges: twoKeeps
        )
        // Overlay 12..14 only intersects second kept range 10..15.
        // Cursor after first kept range = 5. offset_in_range = 12-10 = 2. start = 5+2 = 7.
        // end = 5 + (14-10) = 9.
        check("overlay in second kept range only",
              mapPartialSecond == TimeRange(start: 7, end: 9))

        let mapDegenerate = KeepSegmentCalculator.mapToOutputTimeline(
            sourceStart: 5, sourceEnd: 5, keepRanges: singleKeep
        )
        check("overlay with zero duration returns nil",
              mapDegenerate == nil)

        print("KeepSegmentCalculatorTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // KeepSegmentCalculatorTests

#endif
