import Foundation

// MARK: - GIF Config (JSON payload sent to Python)

struct GifConfig: Encodable {
    let files: [String]
    let config: Settings

    struct Settings: Encodable {
        let resolution: ResolutionConfig
        let frame_rate: Double
        let speed_multiplier: Double
        let loop_count: Int
        let dither_method: String
        let color_count: Int
        let output_format: String
        let webp_quality: Int
        let trim_start: Double
        let trim_end: Double?
        let cut_segments: [[String: Double]]
        let text_overlay: TextOverlayConfig?
    }

    struct ResolutionConfig: Encodable {
        let mode: String
        let scalePercent: Int?
        let width: Int?
        let height: Int?
    }
}

// MARK: - Text Overlay Config (JSON payload for text overlay)

struct TextOverlayConfig: Encodable {
    let text: String
    let start: Double
    let end: Double
    let x: Double
    let y: Double
    let font_size: Int
    let font_name: String
    let bold: Bool
    let italic: Bool
    let color: String
    let shadow: Bool
    let shadow_color: String
    let shadow_x: Int
    let shadow_y: Int
    let gradient_enabled: Bool
    let gradient_start_color: String
    let gradient_end_color: String
    let gradient_angle: Double

    init(from overlay: TextOverlay) {
        self.text = overlay.text
        self.start = overlay.startTime
        self.end = overlay.endTime
        self.x = overlay.positionX
        self.y = overlay.positionY
        self.font_size = overlay.fontSize
        self.font_name = overlay.fontName
        self.bold = overlay.isBold
        self.italic = overlay.isItalic
        self.color = overlay.textColor.ffmpegHex
        self.shadow = overlay.hasShadow
        self.shadow_color = overlay.shadowColor.ffmpegHex
        self.shadow_x = overlay.shadowOffsetX
        self.shadow_y = overlay.shadowOffsetY
        self.gradient_enabled = overlay.gradientEnabled
        self.gradient_start_color = overlay.gradientStartColor.pillowHex
        self.gradient_end_color = overlay.gradientEndColor.pillowHex
        self.gradient_angle = overlay.gradientAngle
    }
}

// MARK: - Merger Config (JSON payload sent to Python)

struct MergerConfig: Encodable {
    let files: [String]
    let config: Settings

    struct Settings: Encodable {
        let output_filename: String
        let aspect_mode: String
        let output_codec: String
        let quality_mode: String
        let quality_value: Double
        let fps_value: Double
        let output_dir: String
    }
}

// MARK: - AppState GIF Config Builder

extension AppState {

    func buildGifConfig() -> GifConfig {
        let loopValue: Int = switch gifLoopMode {
        case .infinite: 0
        case .once: 1
        case .custom: gifLoopCount
        }

        let resolutionConfig: GifConfig.ResolutionConfig = switch gifResolutionMode {
        case .original:
            .init(mode: "original", scalePercent: nil, width: nil, height: nil)
        case .scale:
            .init(mode: "scale", scalePercent: Int(gifScalePercent), width: nil, height: nil)
        case .width:
            .init(mode: "width", scalePercent: nil, width: gifFixedWidth, height: nil)
        case .custom:
            .init(mode: "custom", scalePercent: nil, width: gifCustomWidth, height: gifCustomHeight)
        }

        let textOverlayConfig: TextOverlayConfig? = gifTextOverlay.map {
            TextOverlayConfig(from: $0)
        }

        return GifConfig(
            files: videoFiles.map(\.path),
            config: .init(
                resolution: resolutionConfig,
                frame_rate: gifFrameRate,
                speed_multiplier: gifSpeedMultiplier,
                loop_count: loopValue,
                dither_method: gifDitherMethod.ffmpegValue,
                color_count: Int(gifColorCount),
                output_format: gifOutputFormat.rawValue.lowercased(),
                webp_quality: Int(gifWebPQuality),
                trim_start: gifTrimStart,
                trim_end: gifTrimEnd,
                cut_segments: gifCutSegments.map { ["start": $0.startTime, "end": $0.endTime] },
                text_overlay: textOverlayConfig
            )
        )
    }
}
