import Foundation
import AppKit
import CoreText

// MARK: - FontResolver

/// Resolve a font name plus optional bold/italic traits into a `CTFont`.
///
/// This replaces the legacy Python pipeline's approach of hardcoding `.ttf`
/// file paths under `/System/Library/Fonts/`. That strategy was fragile:
/// path layouts change between macOS versions, user-installed fonts weren't
/// supported, and the Python had to keep a separate `FONT_STYLE_MAP` of
/// bold/italic file variants per family.
///
/// The native approach uses `NSFont` + `NSFontDescriptor.SymbolicTraits` to:
/// - Look up any font registered with the OS, including user-installed ones.
/// - Apply bold/italic via symbolic traits, letting AppKit pick the right variant.
/// - Fall back cleanly to the system font when the requested name isn't found.
///
/// `CTFont` and `NSFont` are toll-free bridged on macOS; the result is cast
/// to `CTFont` for use with Core Text / Core Graphics text drawing APIs.
enum FontResolver {

    /// Lower bound on font size. Guards against zero or negative sizes at the
    /// boundary without failing loudly, since upstream layout code can generate them.
    private static let minimumSize: CGFloat = 1.0

    /// Aliases that should resolve to the macOS system font instead of being
    /// looked up as named faces. `NSFont(name: "SF Pro", ...)` returns nil
    /// because SF Pro is not a regular named face; it must come from
    /// `NSFont.systemFont(ofSize:weight:)`.
    private static let systemFontAliases: Set<String> = [
        "SF Pro",
        "SF Pro Text",
        "SF Pro Display",
        "System",
        ".SF NS",
        ".SF NS Text",
        ".SF NS Display"
    ]

    /// Resolve a font specification to a `CTFont`. Never returns `nil`: if the
    /// requested face is missing or construction fails, falls back to the
    /// system font at the requested size with the requested traits.
    ///
    /// - Parameters:
    ///   - name: Font family name (e.g. "Helvetica", "Menlo") or a system-font alias.
    ///   - size: Point size. Values below `minimumSize` are clamped up.
    ///   - bold: Apply the bold symbolic trait.
    ///   - italic: Apply the italic symbolic trait.
    static func resolve(name: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let clampedSize = max(minimumSize, size)

        // System font alias: skip the NSFont(name:) path entirely
        if systemFontAliases.contains(name) {
            return makeSystemFont(size: clampedSize, bold: bold, italic: italic)
        }

        // Try the named font
        guard let baseFont = NSFont(name: name, size: clampedSize) else {
            // Named font not installed; fall back to system font with requested traits
            return makeSystemFont(size: clampedSize, bold: bold, italic: italic)
        }

        // No traits requested: done
        if !bold && !italic {
            return baseFont as CTFont
        }

        // Apply symbolic traits. If the family has no matching variant,
        // NSFont(descriptor:) returns nil and we fall back to the plain base font.
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }

        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(traits)
        if let styled = NSFont(descriptor: descriptor, size: clampedSize) {
            return styled as CTFont
        }
        return baseFont as CTFont
    } // resolve

    // MARK: - System Font Fallback

    /// Build a system font at the given size with the requested traits.
    /// Used both for explicit "System"/"SF Pro" aliases and as the fallback
    /// when a named font cannot be resolved.
    ///
    /// Bold is applied via `NSFont.Weight`; italic is applied via symbolic
    /// traits because the system font has no "italic weight" dimension.
    private static func makeSystemFont(size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        let base = NSFont.systemFont(ofSize: size, weight: weight)

        if !italic {
            return base as CTFont
        }

        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        if let italicized = NSFont(descriptor: descriptor, size: size) {
            return italicized as CTFont
        }
        return base as CTFont
    } // makeSystemFont
} // FontResolver

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `FontResolver`.
/// Call `FontResolverTests.runAll()` from a scratch entry point under `#if DEBUG`.
///
/// Notes on test strategy:
/// - Named-font tests use `Helvetica` because it is guaranteed present on every
///   macOS system and has explicit Bold / Italic / BoldOblique variants, so
///   `CTFontGetSymbolicTraits` returns deterministic results.
/// - System-font tests assert a BEHAVIORAL contract (bold yields a different
///   face than regular) rather than checking specific trait bits, because
///   AppKit's system-font traits-vs-weight relationship is not part of a
///   stable public contract.
enum FontResolverTests {

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

        // MARK: Named font resolution

        let helvetica = FontResolver.resolve(
            name: "Helvetica", size: 24, bold: false, italic: false
        )
        let helveticaFamily = CTFontCopyFamilyName(helvetica) as String
        check("Helvetica resolves to a Helvetica-family font",
              helveticaFamily.contains("Helvetica"))
        check("requested size is preserved",
              abs(CTFontGetSize(helvetica) - 24) < 0.001)

        // MARK: Bold / italic symbolic traits (Helvetica)

        let helveticaBold = FontResolver.resolve(
            name: "Helvetica", size: 24, bold: true, italic: false
        )
        check("bold request yields bold symbolic trait",
              CTFontGetSymbolicTraits(helveticaBold).contains(.traitBold))

        let helveticaItalic = FontResolver.resolve(
            name: "Helvetica", size: 24, bold: false, italic: true
        )
        check("italic request yields italic symbolic trait",
              CTFontGetSymbolicTraits(helveticaItalic).contains(.traitItalic))

        let helveticaBoldItalic = FontResolver.resolve(
            name: "Helvetica", size: 24, bold: true, italic: true
        )
        let bothTraits = CTFontGetSymbolicTraits(helveticaBoldItalic)
        check("bold + italic request yields both traits",
              bothTraits.contains(.traitBold) && bothTraits.contains(.traitItalic))

        // MARK: Unknown font falls back to system

        let unknownName = "ZZZ_NotAFont_ZZZ_\(UUID().uuidString)"
        let unknown = FontResolver.resolve(
            name: unknownName, size: 18, bold: false, italic: false
        )
        check("unknown font yields a valid CTFont (system fallback)",
              CTFontGetSize(unknown) == 18)

        // MARK: System font aliases

        let sfPro = FontResolver.resolve(
            name: "SF Pro", size: 20, bold: false, italic: false
        )
        check("SF Pro resolves without failure and preserves size",
              CTFontGetSize(sfPro) == 20)

        let systemAlias = FontResolver.resolve(
            name: "System", size: 20, bold: false, italic: false
        )
        check("System alias resolves without failure",
              CTFontGetSize(systemAlias) == 20)

        let sysBold = FontResolver.resolve(
            name: "System", size: 20, bold: true, italic: false
        )
        let sysRegular = FontResolver.resolve(
            name: "System", size: 20, bold: false, italic: false
        )
        let boldPS = CTFontCopyPostScriptName(sysBold) as String
        let regularPS = CTFontCopyPostScriptName(sysRegular) as String
        check("System + bold yields a different face than System + regular",
              boldPS != regularPS)

        let sysItalic = FontResolver.resolve(
            name: "System", size: 20, bold: false, italic: true
        )
        check("System + italic yields italic symbolic trait",
              CTFontGetSymbolicTraits(sysItalic).contains(.traitItalic))

        // MARK: Size clamping

        let zeroSize = FontResolver.resolve(
            name: "Helvetica", size: 0, bold: false, italic: false
        )
        check("zero size is clamped to minimum",
              CTFontGetSize(zeroSize) >= 1.0)

        let negativeSize = FontResolver.resolve(
            name: "Helvetica", size: -5, bold: false, italic: false
        )
        check("negative size is clamped to minimum",
              CTFontGetSize(negativeSize) >= 1.0)

        print("FontResolverTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // FontResolverTests

#endif
