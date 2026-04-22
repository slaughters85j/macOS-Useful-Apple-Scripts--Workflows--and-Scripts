import Foundation
import CoreGraphics

// MARK: - ColorParser

/// Convert color representations into `CGColor` for native drawing.
///
/// Primary use case: bridge the project's `CodableColor` (plain RGBA doubles)
/// into `CGColor` for Core Graphics and Core Text overlay rendering. This is
/// the `CodableColor.cgColor` extension below.
///
/// Secondary use case: parse ffmpeg-style (`0xRRGGBB@0.8`) and HTML-style
/// (`#RRGGBB`, `#RRGGBBAA`) hex strings via `ColorParser.parseHex(_:)`. This
/// helper is NOT on the primary rendering path. The native renderer consumes
/// `CodableColor` directly. It's kept here as the inverse of `CodableColor`'s
/// existing `ffmpegHex` and `pillowHex` serializers, for cases where hex
/// strings arrive from persisted configs or external input.
///
/// All produced `CGColor` values are in the sRGB color space, matching the
/// color space of frames extracted from AVFoundation on macOS.
///
/// Code Reuse Candidate: both the `CodableColor` bridge and the hex parser
/// are useful anywhere in the app that needs `CGColor` values.
enum ColorParser {

    /// Parse an ffmpeg- or HTML-style hex color string into a sRGB `CGColor`.
    ///
    /// Accepted formats:
    /// - `#RRGGBB`       HTML hex, full opacity
    /// - `#RRGGBBAA`     HTML hex with alpha component
    /// - `0xRRGGBB`      ffmpeg hex, full opacity
    /// - `0xRRGGBB@A`    ffmpeg hex with alpha suffix (A in 0.0 to 1.0)
    /// - `RRGGBB`        bare hex, full opacity
    /// - `RRGGBBAA`      bare hex with alpha component
    ///
    /// Returns `nil` for malformed input. An 8-char hex with an `@` alpha suffix
    /// is also rejected as ambiguous (two alpha sources).
    static func parseHex(_ input: String) -> CGColor? {
        var s = input.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Handle ffmpeg-style @alpha suffix first (e.g. "0xFFFFFF@0.8")
        var alphaFromSuffix: CGFloat? = nil
        if let atIndex = s.firstIndex(of: "@") {
            let alphaPart = s[s.index(after: atIndex)...]
            guard let a = Double(alphaPart), a.isFinite, (0...1).contains(a) else {
                return nil
            }
            alphaFromSuffix = CGFloat(a)
            s = String(s[..<atIndex])
        }

        // Strip prefix
        if s.hasPrefix("#") {
            s.removeFirst()
        } else if s.hasPrefix("0x") || s.hasPrefix("0X") {
            s.removeFirst(2)
        }

        // Must now be exactly 6 (RGB) or 8 (RGBA) hex chars
        guard s.count == 6 || s.count == 8 else { return nil }

        // Ambiguous: can't specify alpha both in 8-char form AND via @ suffix
        if s.count == 8 && alphaFromSuffix != nil { return nil }

        guard let rgba = UInt64(s, radix: 16) else { return nil }

        let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
        if s.count == 6 {
            r = CGFloat((rgba >> 16) & 0xFF) / 255.0
            g = CGFloat((rgba >> 8)  & 0xFF) / 255.0
            b = CGFloat( rgba        & 0xFF) / 255.0
            a = alphaFromSuffix ?? 1.0
        } else {
            r = CGFloat((rgba >> 24) & 0xFF) / 255.0
            g = CGFloat((rgba >> 16) & 0xFF) / 255.0
            b = CGFloat((rgba >> 8)  & 0xFF) / 255.0
            a = CGFloat( rgba        & 0xFF) / 255.0
        }

        return CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    } // parseHex
} // ColorParser

// MARK: - CodableColor + CGColor

extension CodableColor {

    /// Convert this color to a sRGB `CGColor` for Core Graphics drawing.
    ///
    /// Channel values are clamped to [0, 1] to prevent out-of-gamut or NaN
    /// components from producing surprise colors or crashes during rendering.
    /// This is defensive: typical construction paths already produce in-range values.
    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(clampChannel(red)),
            green: CGFloat(clampChannel(green)),
            blue: CGFloat(clampChannel(blue)),
            alpha: CGFloat(clampChannel(alpha))
        )
    } // cgColor

    private func clampChannel(_ value: Double) -> Double {
        if !value.isFinite { return 0 }
        return min(max(value, 0), 1)
    } // clampChannel
} // CodableColor

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `ColorParser` and the `CodableColor` bridge.
/// Call `ColorParserTests.runAll()` from a scratch entry point under `#if DEBUG`.
enum ColorParserTests {

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

        /// Compare two CGColors component-wise within a small tolerance.
        /// CGColor's own equality is reference-ish and unreliable across srgb constructors.
        func approximatelyEqual(_ lhs: CGColor?, _ rhs: CGColor?, epsilon: CGFloat = 1e-6) -> Bool {
            guard let l = lhs, let r = rhs else { return lhs == nil && rhs == nil }
            guard let lc = l.components, let rc = r.components else { return false }
            guard lc.count == rc.count else { return false }
            for i in 0..<lc.count {
                if abs(lc[i] - rc[i]) > epsilon { return false }
            }
            return true
        } // approximatelyEqual

        // Reference colors (sRGB) used across tests
        let refWhite = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let refBlack = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let refRed   = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let refClear = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)

        // MARK: CodableColor.cgColor

        check("CodableColor.white -> opaque sRGB white",
              approximatelyEqual(CodableColor.white.cgColor, refWhite))
        check("CodableColor.black -> opaque sRGB black",
              approximatelyEqual(CodableColor.black.cgColor, refBlack))
        check("CodableColor.clear -> fully transparent",
              approximatelyEqual(CodableColor.clear.cgColor, refClear))

        let halfAlpha = CodableColor(red: 1, green: 0, blue: 0, alpha: 0.5).cgColor
        let refHalfAlpha = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
        check("CodableColor red with alpha 0.5 preserves alpha",
              approximatelyEqual(halfAlpha, refHalfAlpha))

        let outOfRange = CodableColor(red: 1.5, green: -0.2, blue: 2.0, alpha: 1.5).cgColor
        let refMagenta = CGColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        check("CodableColor out-of-range channels are clamped to [0,1]",
              approximatelyEqual(outOfRange, refMagenta))

        let nanColor = CodableColor(red: .nan, green: 0.5, blue: 0.5, alpha: 1).cgColor
        let refNanBlack = CGColor(srgbRed: 0, green: 0.5, blue: 0.5, alpha: 1)
        check("CodableColor NaN channel becomes 0",
              approximatelyEqual(nanColor, refNanBlack))

        // MARK: parseHex - HTML #RRGGBB

        check("parseHex #FFFFFF is white",
              approximatelyEqual(ColorParser.parseHex("#FFFFFF"), refWhite))
        check("parseHex #000000 is black",
              approximatelyEqual(ColorParser.parseHex("#000000"), refBlack))
        check("parseHex #FF0000 is red",
              approximatelyEqual(ColorParser.parseHex("#FF0000"), refRed))
        check("parseHex lowercase hex works",
              approximatelyEqual(ColorParser.parseHex("#ff0000"), refRed))

        // MARK: parseHex - HTML #RRGGBBAA

        let halfRedHex = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 128.0/255.0)
        check("parseHex #FF000080 is red with alpha 128/255",
              approximatelyEqual(ColorParser.parseHex("#FF000080"), halfRedHex))

        let fullAlphaHex = ColorParser.parseHex("#FF0000FF")
        check("parseHex #FF0000FF is fully opaque red",
              approximatelyEqual(fullAlphaHex, refRed))

        // MARK: parseHex - ffmpeg 0xRRGGBB and 0xRRGGBB@A

        check("parseHex 0xFFFFFF is white",
              approximatelyEqual(ColorParser.parseHex("0xFFFFFF"), refWhite))
        check("parseHex 0XFFFFFF (uppercase prefix) works",
              approximatelyEqual(ColorParser.parseHex("0XFFFFFF"), refWhite))

        let halfWhite = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.5)
        check("parseHex 0xFFFFFF@0.5 is white with alpha 0.5",
              approximatelyEqual(ColorParser.parseHex("0xFFFFFF@0.5"), halfWhite))

        check("parseHex 0x000000@1.0 is opaque black",
              approximatelyEqual(ColorParser.parseHex("0x000000@1.0"), refBlack))

        let zeroAlpha = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)
        check("parseHex 0xFFFFFF@0 is fully transparent",
              approximatelyEqual(ColorParser.parseHex("0xFFFFFF@0"), zeroAlpha))

        // MARK: parseHex - bare hex

        check("parseHex bare FF0000 is red",
              approximatelyEqual(ColorParser.parseHex("FF0000"), refRed))

        check("parseHex bare FF000080 is red with 128/255 alpha",
              approximatelyEqual(ColorParser.parseHex("FF000080"), halfRedHex))

        // MARK: parseHex - whitespace

        check("parseHex trims whitespace",
              approximatelyEqual(ColorParser.parseHex("  #FF0000  "), refRed))

        // MARK: parseHex - invalid inputs

        check("parseHex empty string returns nil",
              ColorParser.parseHex("") == nil)
        check("parseHex non-hex chars return nil",
              ColorParser.parseHex("#ZZZZZZ") == nil)
        check("parseHex 5 hex chars returns nil",
              ColorParser.parseHex("#FFFFF") == nil)
        check("parseHex 7 hex chars returns nil",
              ColorParser.parseHex("#FFFFFFF") == nil)
        check("parseHex alpha suffix out of range returns nil",
              ColorParser.parseHex("0xFF0000@1.5") == nil)
        check("parseHex negative alpha suffix returns nil",
              ColorParser.parseHex("0xFF0000@-0.1") == nil)
        check("parseHex non-numeric alpha suffix returns nil",
              ColorParser.parseHex("0xFF0000@foo") == nil)
        check("parseHex 8-char hex with @alpha suffix is ambiguous, returns nil",
              ColorParser.parseHex("0xFF000080@0.5") == nil)

        print("ColorParserTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // ColorParserTests

#endif
