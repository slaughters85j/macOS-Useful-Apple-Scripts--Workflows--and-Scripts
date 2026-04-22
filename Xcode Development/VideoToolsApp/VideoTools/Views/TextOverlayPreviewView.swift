import SwiftUI

// MARK: - Text Overlay Preview View

/// Displays the styled text overlay on top of the video preview thumbnail.
/// Supports drag-to-reposition and tap-to-edit.
struct TextOverlayPreviewView: View {
    @Binding var textOverlay: TextOverlay?
    let scrubberPosition: Double
    var onTap: () -> Void

    var body: some View {
        GeometryReader { geometry in
            if let overlay = textOverlay, isVisible(overlay) {
                styledText(for: overlay)
                    .position(
                        x: overlay.positionX * geometry.size.width,
                        y: overlay.positionY * geometry.size.height
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                guard var current = textOverlay else { return }
                                current.positionX = clamp(
                                    value.location.x / geometry.size.width, min: 0.05, max: 0.95
                                )
                                current.positionY = clamp(
                                    value.location.y / geometry.size.height, min: 0.05, max: 0.95
                                )
                                textOverlay = current
                            }
                    )
                    .onTapGesture {
                        onTap()
                    }
            }
        }
    }

    // MARK: - Styled Text

    @ViewBuilder
    private func styledText(for overlay: TextOverlay) -> some View {
        let baseFont = resolveFont(overlay)

        Text(overlay.text)
            .font(Font(baseFont))
            .foregroundStyle(foregroundStyle(for: overlay))
            .shadow(
                color: overlay.hasShadow ? overlay.shadowColor.swiftUIColor : .clear,
                radius: overlay.hasShadow ? 1 : 0,
                x: CGFloat(overlay.shadowOffsetX),
                y: CGFloat(overlay.shadowOffsetY)
            )
            .fixedSize()
    }

    // MARK: - Font Resolution

    private func resolveFont(_ overlay: TextOverlay) -> NSFont {
        let size = CGFloat(overlay.fontSize) * 0.35  // Scale down for preview
        var traits: NSFontTraitMask = []
        if overlay.isBold { traits.insert(.boldFontMask) }
        if overlay.isItalic { traits.insert(.italicFontMask) }

        if let font = NSFontManager.shared.font(
            withFamily: overlay.fontName,
            traits: traits,
            weight: overlay.isBold ? 9 : 5,
            size: size
        ) {
            return font
        }

        return NSFont.systemFont(ofSize: size, weight: overlay.isBold ? .bold : .regular)
    }

    // MARK: - Foreground Style

    private func foregroundStyle(for overlay: TextOverlay) -> some ShapeStyle {
        if overlay.gradientEnabled {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        overlay.gradientStartColor.swiftUIColor,
                        overlay.gradientEndColor.swiftUIColor
                    ],
                    startPoint: gradientStartPoint(overlay.gradientAngle),
                    endPoint: gradientEndPoint(overlay.gradientAngle)
                )
            )
        } else {
            return AnyShapeStyle(overlay.textColor.swiftUIColor)
        }
    }

    // MARK: - Helpers

    private func isVisible(_ overlay: TextOverlay) -> Bool {
        !overlay.text.isEmpty &&
        scrubberPosition >= overlay.startTime &&
        scrubberPosition <= overlay.endTime
    }

    private func clamp(_ value: Double, min minVal: Double, max maxVal: Double) -> Double {
        Swift.min(maxVal, Swift.max(minVal, value))
    }

    private func gradientStartPoint(_ angle: Double) -> UnitPoint {
        let radians = angle * .pi / 180
        return UnitPoint(
            x: 0.5 - cos(radians) * 0.5,
            y: 0.5 - sin(radians) * 0.5
        )
    }

    private func gradientEndPoint(_ angle: Double) -> UnitPoint {
        let radians = angle * .pi / 180
        return UnitPoint(
            x: 0.5 + cos(radians) * 0.5,
            y: 0.5 + sin(radians) * 0.5
        )
    }
}
