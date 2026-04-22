import Foundation
import SwiftUI

// MARK: - GIF Resolution

enum GifResolutionMode: String, CaseIterable, Identifiable {
    case original = "Original"
    case scale = "Scale %"
    case width = "Fixed Width"
    case custom = "Custom"

    var id: String { rawValue }
}

// MARK: - GIF Loop Mode

enum GifLoopMode: String, CaseIterable, Identifiable {
    case infinite = "Infinite"
    case once = "Play Once"
    case custom = "Custom Count"

    var id: String { rawValue }
}

// MARK: - GIF Output Format

enum GifOutputFormat: String, CaseIterable, Identifiable {
    case gif = "GIF"
    case apng = "APNG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .gif:  return "gif"
        case .apng: return "png"
        }
    }
}

// MARK: - Cut Segment

/// Represents a segment to REMOVE from the video
struct CutSegment: Identifiable, Codable, Hashable {
    let id: UUID
    var startTime: Double
    var endTime: Double

    init(id: UUID = UUID(), startTime: Double, endTime: Double) {
        self.id = id
        self.startTime = startTime
        self.endTime = endTime
    }

    var duration: Double { endTime - startTime }

    var displayRange: String {
        "\(formatTime(startTime)) - \(formatTime(endTime))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

// MARK: - Codable Color

/// A Codable wrapper for Color that stores RGBA components.
/// Provides conversion to SwiftUI Color, NSColor, and FFmpeg hex format.
struct CodableColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    // MARK: Conversions

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// FFmpeg hex format: "0xRRGGBB@A" where A is 0.0-1.0
    var ffmpegHex: String {
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)
        return String(format: "0x%02X%02X%02X@%.1f", r, g, b, alpha)
    }

    /// Hex string for Pillow: "#RRGGBB"
    var pillowHex: String {
        let r = Int(red * 255)
        let g = Int(green * 255)
        let b = Int(blue * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    // MARK: Initializers

    init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(from nsColor: NSColor) {
        let converted = nsColor.usingColorSpace(.sRGB) ?? nsColor
        self.red = Double(converted.redComponent)
        self.green = Double(converted.greenComponent)
        self.blue = Double(converted.blueComponent)
        self.alpha = Double(converted.alphaComponent)
    }

    // MARK: Presets

    static var white: CodableColor {
        CodableColor(red: 1, green: 1, blue: 1)
    }

    static var black: CodableColor {
        CodableColor(red: 0, green: 0, blue: 0)
    }

    static var clear: CodableColor {
        CodableColor(red: 0, green: 0, blue: 0, alpha: 0)
    }
}

// MARK: - Text Overlay

/// A styled text overlay that appears on the GIF output during a specified time range.
struct TextOverlay: Identifiable, Codable, Hashable {
    let id: UUID
    var text: String
    var startTime: Double           // when text appears (seconds)
    var endTime: Double             // when text disappears (seconds)

    // Position (normalized 0-1, relative to output dimensions)
    var positionX: Double           // 0 = left edge, 1 = right edge
    var positionY: Double           // 0 = top edge, 1 = bottom edge

    // Font
    var fontSize: Int               // 12-120
    var fontName: String            // from curated font list
    var isBold: Bool
    var isItalic: Bool

    // Color
    var textColor: CodableColor

    // Shadow
    var hasShadow: Bool
    var shadowColor: CodableColor
    var shadowOffsetX: Int
    var shadowOffsetY: Int

    // Gradient
    var gradientEnabled: Bool
    var gradientStartColor: CodableColor
    var gradientEndColor: CodableColor
    var gradientAngle: Double       // degrees, 0 = left-to-right

    // MARK: Initializer

    init(
        id: UUID = UUID(),
        text: String = "Text",
        startTime: Double,
        endTime: Double,
        positionX: Double = 0.5,
        positionY: Double = 0.5,
        fontSize: Int = 48,
        fontName: String = "Helvetica",
        isBold: Bool = false,
        isItalic: Bool = false,
        textColor: CodableColor = .white,
        hasShadow: Bool = true,
        shadowColor: CodableColor = .black,
        shadowOffsetX: Int = 2,
        shadowOffsetY: Int = 2,
        gradientEnabled: Bool = false,
        gradientStartColor: CodableColor = .white,
        gradientEndColor: CodableColor = CodableColor(red: 0.3, green: 0.6, blue: 1.0),
        gradientAngle: Double = 0
    ) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.positionX = positionX
        self.positionY = positionY
        self.fontSize = fontSize
        self.fontName = fontName
        self.isBold = isBold
        self.isItalic = isItalic
        self.textColor = textColor
        self.hasShadow = hasShadow
        self.shadowColor = shadowColor
        self.shadowOffsetX = shadowOffsetX
        self.shadowOffsetY = shadowOffsetY
        self.gradientEnabled = gradientEnabled
        self.gradientStartColor = gradientStartColor
        self.gradientEndColor = gradientEndColor
        self.gradientAngle = gradientAngle
    }

    var displayRange: String {
        "\(formatTime(startTime)) - \(formatTime(endTime))"
    }

    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%d:%05.2f", mins, secs)
    }
}

// MARK: - Curated Font List

/// Fonts known to exist on all modern macOS versions with their file paths.
/// Used for the font picker UI and mapped to file paths in the Python pipeline.
enum CuratedFont: String, CaseIterable, Identifiable {
    case helvetica = "Helvetica"
    case arial = "Arial"
    case courier = "Courier"
    case courierNew = "Courier New"
    case georgia = "Georgia"
    case timesNewRoman = "Times New Roman"
    case menlo = "Menlo"
    case sfPro = "SF Pro"
    case avenir = "Avenir"
    case futura = "Futura"
    case didot = "Didot"
    case palatino = "Palatino"
    case optima = "Optima"
    case trebuchetMS = "Trebuchet MS"
    case verdana = "Verdana"
    case impact = "Impact"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

// MARK: - GIF Settings (Legacy per-file settings)

struct GifSettings: Codable {
    var resolutionMode: String = "original"
    var scalePercent: Int = 50
    var fixedWidth: Int = 480
    var customWidth: Int = 640
    var customHeight: Int = 480

    var frameRate: Double = 15
    var speedMultiplier: Double = 1.0

    var loopMode: String = "infinite"
    var loopCount: Int = 3

    var trimStart: Double = 0
    var trimEnd: Double? = nil
    var cutSegments: [CutSegment] = []
}
