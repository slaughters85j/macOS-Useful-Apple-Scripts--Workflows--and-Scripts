import Foundation
import CoreMedia

// MARK: - SplitSegmentCalculator

/// Pure segment math for the native video splitter.
///
/// Given a source duration and a split specification (by-duration or by-count),
/// produces a non-overlapping, duration-covering list of `CMTimeRange`s that
/// together span the full source timeline. The output is consumed by the
/// `VideoSplitter` orchestrator, which dispatches each range to a segment
/// exporter (passthrough or re-encode) and writes one output file per range.
///
/// Everything here is a pure static function. No I/O, no state. Call sites
/// do not need to be actors.
///
/// Code Reuse Candidate: The range-covering math is splitter-specific, but the
/// duration-to-count and count-to-duration decomposition logic is generic and
/// could be lifted into a shared utility if Separate A/V ever grows a similar
/// batch-by-duration mode.
enum SplitSegmentCalculator {

    // MARK: - Public API

    /// Compute the list of source-timeline ranges that should be exported as
    /// individual segments.
    ///
    /// - Parameters:
    ///   - sourceDuration: Full source video duration in seconds. Must be > 0.
    ///   - method: Split strategy. `.duration` slices every `splitValue`
    ///             seconds. `.segments` produces exactly `Int(splitValue)`
    ///             equal-duration segments. `.reencodeOnly` is treated as a
    ///             single segment covering the full duration (matches the
    ///             legacy `AppState.splitValueInSeconds` convention of
    ///             returning 1 for re-encode-only).
    ///   - splitValue: For `.duration`, seconds per segment. For `.segments`,
    ///                 integer count (non-integer values are floored to the
    ///                 nearest positive integer). For `.reencodeOnly`, ignored.
    ///   - timescale: `CMTimeScale` used to build returned `CMTimeRange`s. Pass
    ///                `600` for standard SD/HD use or `90000` when working with
    ///                high-fps material; the splitter uses `600` by default.
    /// - Returns: Zero or more non-overlapping `CMTimeRange`s, in source-time
    ///            order, whose union is `[0, sourceDuration)`. Returns an empty
    ///            array if inputs are degenerate (zero/negative duration, or a
    ///            `splitValue` that cannot produce a valid segment).
    static func segmentRanges(
        sourceDuration: Double,
        method: SplitMethod,
        splitValue: Double,
        timescale: CMTimeScale = 600
    ) -> [CMTimeRange] {

        guard sourceDuration > 0 else { return [] }

        switch method {

        case .reencodeOnly:
            // The whole clip is re-emitted as a single segment. Matches the
            // legacy Python behavior where re-encode-only meant "one segment".
            return [rangeInSeconds(start: 0, end: sourceDuration, timescale: timescale)]

        case .duration:
            // Slice every `splitValue` seconds. The last segment may be shorter
            // than `splitValue` when `sourceDuration` is not a clean multiple.
            guard splitValue > 0 else { return [] }
            var ranges: [CMTimeRange] = []
            var cursor: Double = 0
            while cursor < sourceDuration {
                let end = min(cursor + splitValue, sourceDuration)
                // Guard against pathological float arithmetic that could emit
                // a zero-length tail segment.
                if end > cursor {
                    ranges.append(rangeInSeconds(start: cursor, end: end, timescale: timescale))
                }
                cursor = end
            }
            return ranges

        case .segments:
            // Divide into exactly N equal segments. Any fractional/negative N
            // is clamped to 1 so the caller always gets a usable split rather
            // than an empty result.
            let count = max(1, Int(splitValue.rounded(.down)))
            let perSegment = sourceDuration / Double(count)
            var ranges: [CMTimeRange] = []
            ranges.reserveCapacity(count)
            for i in 0 ..< count {
                let start = Double(i) * perSegment
                // The last segment explicitly clamps to `sourceDuration` to
                // avoid float-drift overshoot after repeated multiplication.
                let end = (i == count - 1) ? sourceDuration : Double(i + 1) * perSegment
                ranges.append(rangeInSeconds(start: start, end: end, timescale: timescale))
            }
            return ranges
        }
    } // segmentRanges

    // MARK: - Helpers

    /// Build a `CMTimeRange` from a start and end expressed in seconds, using
    /// the supplied integer timescale for both endpoints.
    ///
    /// Internal helper. Kept file-private to the namespace so the conversion
    /// rule is consistent across the calculator.
    private static func rangeInSeconds(
        start: Double,
        end: Double,
        timescale: CMTimeScale
    ) -> CMTimeRange {
        let startTime = CMTime(seconds: start, preferredTimescale: timescale)
        let endTime = CMTime(seconds: end, preferredTimescale: timescale)
        return CMTimeRange(start: startTime, end: endTime)
    } // rangeInSeconds
} // SplitSegmentCalculator

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `SplitSegmentCalculator`.
/// Call `SplitSegmentCalculatorTests.runAll()` from a scratch entry point
/// under `#if DEBUG` to exercise the pure math paths.
enum SplitSegmentCalculatorTests {

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

        func seconds(_ range: CMTimeRange) -> (start: Double, end: Double) {
            (range.start.seconds, range.end.seconds)
        } // seconds

        // MARK: degenerate input

        let zeroDuration = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 0, method: .duration, splitValue: 5
        )
        check("zero source duration returns empty", zeroDuration.isEmpty)

        let negativeDuration = SplitSegmentCalculator.segmentRanges(
            sourceDuration: -10, method: .duration, splitValue: 5
        )
        check("negative source duration returns empty", negativeDuration.isEmpty)

        let zeroSplitValue = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 10, method: .duration, splitValue: 0
        )
        check("zero splitValue for duration mode returns empty", zeroSplitValue.isEmpty)

        // MARK: reencodeOnly

        let reencode = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 42.5, method: .reencodeOnly, splitValue: 999
        )
        check("reencodeOnly produces one segment spanning full duration",
              reencode.count == 1 &&
              abs(seconds(reencode[0]).start - 0) < 1e-6 &&
              abs(seconds(reencode[0]).end - 42.5) < 1e-6)

        // MARK: duration mode, exact multiple

        let exactDuration = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 10, method: .duration, splitValue: 2.5
        )
        check("duration mode with exact multiple gives 4 equal segments",
              exactDuration.count == 4 &&
              abs(seconds(exactDuration[0]).start - 0) < 1e-6 &&
              abs(seconds(exactDuration[3]).end - 10) < 1e-6)

        // MARK: duration mode, inexact (tail segment shorter)

        let inexactDuration = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 10, method: .duration, splitValue: 3
        )
        // Expect 4 segments: 0..3, 3..6, 6..9, 9..10
        check("duration mode with remainder produces short tail",
              inexactDuration.count == 4 &&
              abs(seconds(inexactDuration[3]).start - 9) < 1e-6 &&
              abs(seconds(inexactDuration[3]).end - 10) < 1e-6)

        // MARK: duration mode, splitValue > duration

        let oversized = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 5, method: .duration, splitValue: 100
        )
        check("duration larger than source produces single segment",
              oversized.count == 1 &&
              abs(seconds(oversized[0]).start - 0) < 1e-6 &&
              abs(seconds(oversized[0]).end - 5) < 1e-6)

        // MARK: segments mode, basic

        let threeSegments = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 30, method: .segments, splitValue: 3
        )
        check("segments mode with N=3 produces 3 equal segments",
              threeSegments.count == 3 &&
              abs(seconds(threeSegments[0]).end - 10) < 1e-6 &&
              abs(seconds(threeSegments[1]).end - 20) < 1e-6 &&
              abs(seconds(threeSegments[2]).end - 30) < 1e-6)

        // MARK: segments mode, N=1

        let oneSegment = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 15, method: .segments, splitValue: 1
        )
        check("segments mode with N=1 equals full duration",
              oneSegment.count == 1 &&
              abs(seconds(oneSegment[0]).end - 15) < 1e-6)

        // MARK: segments mode, zero/negative N clamped to 1

        let zeroSegments = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 15, method: .segments, splitValue: 0
        )
        check("segments with N=0 clamps to N=1",
              zeroSegments.count == 1)

        let negativeSegments = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 15, method: .segments, splitValue: -3
        )
        check("segments with N<0 clamps to N=1",
              negativeSegments.count == 1)

        // MARK: segments mode, non-integer N floored

        let flooredSegments = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 12, method: .segments, splitValue: 3.8
        )
        check("segments with non-integer N floors to 3",
              flooredSegments.count == 3)

        // MARK: coverage invariant

        let coverage = SplitSegmentCalculator.segmentRanges(
            sourceDuration: 17.3, method: .duration, splitValue: 4
        )
        let firstStart = coverage.first.map { seconds($0).start } ?? -1
        let lastEnd = coverage.last.map { seconds($0).end } ?? -1
        var contiguous = true
        for i in 1 ..< coverage.count {
            if abs(seconds(coverage[i]).start - seconds(coverage[i - 1]).end) > 1e-6 {
                contiguous = false
                break
            }
        }
        check("coverage invariant: starts at 0, ends at duration, contiguous",
              abs(firstStart - 0) < 1e-6 &&
              abs(lastEnd - 17.3) < 1e-6 &&
              contiguous)

        print("SplitSegmentCalculatorTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // SplitSegmentCalculatorTests

#endif
