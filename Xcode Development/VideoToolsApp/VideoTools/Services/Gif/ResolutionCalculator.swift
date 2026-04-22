import Foundation

// MARK: - ResolutionCalculator

/// Pure resolution math for GIF rendering.
///
/// Given a `ResolutionSpec` and source video dimensions, compute the final
/// output pixel dimensions. Output dimensions are always clamped to at least
/// `minimumDimension` on each axis.
///
/// Policy decisions encoded here:
/// - `.scalePercent` truncates toward zero then rounds up to the nearest even
///   pixel per dimension. This matches the legacy Python's `int(src * pct)` +
///   `+1 if odd` pattern.
/// - `.fixedWidth` keeps the caller-supplied width verbatim and computes height
///   via `round(src_h * w / src_w / 2) * 2`, which yields the nearest multiple of 2.
///   This matches ffmpeg's `scale=W:-2` behavior that the Python relied on, and
///   uses Swift's `.toNearestOrEven` rounding rule to match Python 3's banker's
///   rounding exactly. This matters because Swift's default `.rounded()` is
///   ties-away-from-zero and would produce off-by-two heights on halfway values.
/// - `.custom` passes both dimensions through verbatim (trust the user).
/// - `.original` uses source dimensions verbatim.
///
/// The native pipeline does NOT strictly require even dimensions the way the
/// legacy libx264 intermediate did. Even-rounding is preserved purely for output
/// parity with the old renderer so users don't see a 1-pixel drift after the port.
enum ResolutionCalculator {

    /// Minimum output dimension, enforced on both axes.
    static let minimumDimension = 2

    /// Compute final output dimensions for a resolution spec and source size.
    ///
    /// - Parameters:
    ///   - spec: The resolution directive.
    ///   - sourceWidth: Source video width in pixels. Expected > 0.
    ///   - sourceHeight: Source video height in pixels. Expected > 0.
    /// - Returns: Final output (width, height), each at least `minimumDimension`.
    static func outputDimensions(
        spec: ResolutionSpec,
        sourceWidth: Int,
        sourceHeight: Int
    ) -> (width: Int, height: Int) {

        switch spec {

        case .original:
            return clampToMinimum(sourceWidth, sourceHeight)

        case .scalePercent(let percent):
            // NaN or non-positive percent falls back to source dimensions.
            // The validator in GifRenderConfig catches most of these, but
            // defensive behavior here avoids crashing on bad data at runtime.
            guard percent.isFinite, percent > 0 else {
                return clampToMinimum(sourceWidth, sourceHeight)
            }
            let clampedPercent = min(percent, 1.0)
            let wRaw = Int(Double(sourceWidth) * clampedPercent)
            let hRaw = Int(Double(sourceHeight) * clampedPercent)
            return clampToMinimum(roundUpToEven(wRaw), roundUpToEven(hRaw))

        case .fixedWidth(let width):
            // Compute aspect-preserving height. Matches Python 3 banker's rounding
            // via Swift's `.toNearestOrEven` rule. See the file-level doc for why.
            guard sourceWidth > 0 else {
                return clampToMinimum(width, width)
            }
            let rawHeight = Double(sourceHeight) * Double(width) / Double(sourceWidth)
            let h = Int((rawHeight / 2.0).rounded(.toNearestOrEven)) * 2
            return clampToMinimum(width, h)

        case .custom(let w, let h):
            return clampToMinimum(w, h)
        }
    } // outputDimensions

    // MARK: - Helpers

    /// Round an integer up to the nearest even value.
    /// Zero and negative inputs are floored to `minimumDimension`.
    ///
    /// Code Reuse Candidate: generic even-rounding helper useful in any pixel math.
    static func roundUpToEven(_ value: Int) -> Int {
        if value <= 0 { return minimumDimension }
        return value.isMultiple(of: 2) ? value : value + 1
    } // roundUpToEven

    /// Clamp both dimensions to at least `minimumDimension`.
    private static func clampToMinimum(_ w: Int, _ h: Int) -> (width: Int, height: Int) {
        return (max(w, minimumDimension), max(h, minimumDimension))
    } // clampToMinimum
} // ResolutionCalculator

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `ResolutionCalculator`.
/// Call `ResolutionCalculatorTests.runAll()` from a scratch entry point under `#if DEBUG`.
enum ResolutionCalculatorTests {

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

        // MARK: .original

        let origStandard = ResolutionCalculator.outputDimensions(
            spec: .original, sourceWidth: 1920, sourceHeight: 1080
        )
        check("original returns source dimensions verbatim",
              origStandard == (1920, 1080))

        let origOdd = ResolutionCalculator.outputDimensions(
            spec: .original, sourceWidth: 641, sourceHeight: 481
        )
        check("original keeps odd source dimensions",
              origOdd == (641, 481))

        let origTiny = ResolutionCalculator.outputDimensions(
            spec: .original, sourceWidth: 1, sourceHeight: 1
        )
        check("original with 1x1 source is clamped to minimum 2x2",
              origTiny == (2, 2))

        // MARK: .scalePercent

        let half1080p = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(0.5), sourceWidth: 1920, sourceHeight: 1080
        )
        check("scale 0.5 on 1920x1080 is 960x540",
              half1080p == (960, 540))

        let thirdSize = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(0.5), sourceWidth: 1001, sourceHeight: 333
        )
        // 1001 * 0.5 = 500.5 -> Int() truncates to 500, even, kept
        // 333 * 0.5 = 166.5 -> Int() truncates to 166, even, kept
        check("scale 0.5 on 1001x333 truncates then keeps even",
              thirdSize == (500, 166))

        let oddRound = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(0.5), sourceWidth: 1003, sourceHeight: 337
        )
        // 1003 * 0.5 = 501.5 -> Int() = 501, odd, +1 -> 502
        // 337 * 0.5 = 168.5 -> Int() = 168, even, kept
        check("scale 0.5 rounds up to even when truncation is odd",
              oddRound == (502, 168))

        let tinyScale = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(0.01), sourceWidth: 100, sourceHeight: 100
        )
        // 100 * 0.01 = 1.0 -> Int() = 1 -> roundUpToEven(1) = 2
        check("scale 0.01 on 100x100 is clamped to 2x2",
              tinyScale == (2, 2))

        let scale100 = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(1.0), sourceWidth: 640, sourceHeight: 480
        )
        check("scale 1.0 is identity on already-even dimensions",
              scale100 == (640, 480))

        let scaleOverOne = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(2.0), sourceWidth: 640, sourceHeight: 480
        )
        check("scale > 1.0 is clamped to 1.0",
              scaleOverOne == (640, 480))

        let scaleNegative = ResolutionCalculator.outputDimensions(
            spec: .scalePercent(-0.5), sourceWidth: 640, sourceHeight: 480
        )
        check("scale < 0 falls back to source dimensions",
              scaleNegative == (640, 480))

        // MARK: .fixedWidth

        let fw640 = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(640), sourceWidth: 1920, sourceHeight: 1080
        )
        check("fixedWidth 640 on 1920x1080 is 640x360",
              fw640 == (640, 360))

        let fwSquare = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(100), sourceWidth: 1000, sourceHeight: 1000
        )
        check("fixedWidth 100 on square source is 100x100",
              fwSquare == (100, 100))

        let fwPortrait = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(300), sourceWidth: 1080, sourceHeight: 1920
        )
        // rawHeight = 1920 * 300 / 1080 = 533.33...
        // rawHeight / 2 = 266.66... (not a tie), rounds to nearest = 267
        // 267 * 2 = 534
        check("fixedWidth 300 on portrait 1080x1920 is 300x534",
              fwPortrait == (300, 534))

        let fwTies = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(481), sourceWidth: 1000, sourceHeight: 1000
        )
        // rawHeight = 1000 * 481 / 1000 = 481.0
        // rawHeight / 2 = 240.5 -> ties-to-even -> 240
        // 240 * 2 = 480
        check("fixedWidth 481 on 1000x1000 rounds halfway height ties-to-even",
              fwTies == (481, 480))

        let fwOddWidth = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(641), sourceWidth: 1920, sourceHeight: 1080
        )
        // Width stays verbatim (user choice), height still rounded to nearest even.
        // rawHeight = 1080 * 641 / 1920 = 360.5625
        // / 2 = 180.28125 -> rounds to 180
        // * 2 = 360
        check("fixedWidth keeps odd user width verbatim",
              fwOddWidth == (641, 360))

        let fwZeroSrc = ResolutionCalculator.outputDimensions(
            spec: .fixedWidth(100), sourceWidth: 0, sourceHeight: 100
        )
        check("fixedWidth with zero source width falls back to square",
              fwZeroSrc == (100, 100))

        // MARK: .custom

        let custEven = ResolutionCalculator.outputDimensions(
            spec: .custom(width: 640, height: 480),
            sourceWidth: 1920, sourceHeight: 1080
        )
        check("custom dimensions pass through verbatim",
              custEven == (640, 480))

        let custOdd = ResolutionCalculator.outputDimensions(
            spec: .custom(width: 641, height: 481),
            sourceWidth: 1920, sourceHeight: 1080
        )
        check("custom dimensions do NOT round to even",
              custOdd == (641, 481))

        let custTiny = ResolutionCalculator.outputDimensions(
            spec: .custom(width: 1, height: 1),
            sourceWidth: 1920, sourceHeight: 1080
        )
        check("custom 1x1 is clamped to 2x2",
              custTiny == (2, 2))

        // MARK: roundUpToEven helper

        check("roundUpToEven(0) clamps to minimum",
              ResolutionCalculator.roundUpToEven(0) == 2)
        check("roundUpToEven(-5) clamps to minimum",
              ResolutionCalculator.roundUpToEven(-5) == 2)
        check("roundUpToEven(1) rounds up to 2",
              ResolutionCalculator.roundUpToEven(1) == 2)
        check("roundUpToEven(2) stays 2",
              ResolutionCalculator.roundUpToEven(2) == 2)
        check("roundUpToEven(3) rounds up to 4",
              ResolutionCalculator.roundUpToEven(3) == 4)
        check("roundUpToEven(100) stays 100",
              ResolutionCalculator.roundUpToEven(100) == 100)
        check("roundUpToEven(101) rounds up to 102",
              ResolutionCalculator.roundUpToEven(101) == 102)

        print("ResolutionCalculatorTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // ResolutionCalculatorTests

#endif
