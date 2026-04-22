import Foundation
import AppKit
import CoreGraphics
import CoreText

// MARK: - TextOverlayRenderer

/// Native text overlay renderer for GIF/APNG frames.
///
/// Replaces two distinct paths in the legacy Python pipeline:
/// - Solid-color text was drawn by ffmpeg's `drawtext` filter.
/// - Gradient text was rendered to a transparent PNG by Pillow, then overlaid by ffmpeg.
///
/// Both collapse into one native path here using Core Graphics + Core Text, with
/// optional shadow via `CGContext.setShadow(...)` and gradient fill via
/// mask-clipped linear gradient.
///
/// ### Coordinate system contract
/// The caller's `CGContext` MUST use standard Core Graphics bottom-left-origin
/// coordinates. The frame pipeline builds its bitmap context that way, so this
/// matches typical usage. If a flipped context is ever needed, apply the flip
/// OUTSIDE this renderer and this renderer's output will follow suit.
///
/// ### Overlay position
/// `positionX` / `positionY` are normalized to `[0, 1]` in the user's (top-left
/// origin) mental model, with `(0.5, 0.5)` meaning dead center of the canvas.
/// The text's CENTER is placed at that coordinate to match SwiftUI `.position()`.
///
/// ### Gradient angle
/// Mathematical convention: `0°` = horizontal left-to-right, counterclockwise
/// increasing. Matches the legacy Python's gradient math exactly.
enum TextOverlayRenderer {

    // MARK: - Public API

    /// Draw the text overlay into the given context at the given canvas size.
    ///
    /// - Parameters:
    ///   - overlay: The overlay specification. Empty `text` is a no-op.
    ///   - context: Target context. Must use standard CG bottom-left-origin coords.
    ///   - canvasWidth: Width of the canvas in pixels (for normalized positioning).
    ///   - canvasHeight: Height of the canvas in pixels (for normalized positioning).
    static func draw(
        overlay: TextOverlay,
        in context: CGContext,
        canvasWidth: Int,
        canvasHeight: Int
    ) {
        let text = overlay.text
        guard !text.isEmpty else { return }
        guard canvasWidth > 0, canvasHeight > 0 else { return }

        // Resolve font via Core Text bridge
        let font = FontResolver.resolve(
            name: overlay.fontName,
            size: CGFloat(overlay.fontSize),
            bold: overlay.isBold,
            italic: overlay.isItalic
        )

        // Build the attributed string once for measurement and solid-color drawing
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: overlay.textColor.cgColor
        ]
        let attrString = NSAttributedString(string: text, attributes: baseAttrs)
        let textSize = attrString.size()
        guard textSize.width > 0, textSize.height > 0 else { return }


        // Position: user's (x, y) are in top-left-origin normalized coords, and the
        // text's CENTER gets placed there. Convert to bottom-left-origin for CG.
        let cx = overlay.positionX * CGFloat(canvasWidth)
        let cyTop = overlay.positionY * CGFloat(canvasHeight)
        let cyBot = CGFloat(canvasHeight) - cyTop

        let origin = CGPoint(
            x: cx - textSize.width / 2,
            y: cyBot - textSize.height / 2
        )
        let textRect = CGRect(origin: origin, size: textSize)

        // Apply shadow if requested (wraps subsequent drawing).
        // User's shadow Y is "positive = down" (screen convention). CG's shadow
        // offset Y is "positive = up" (bottom-left-origin). Negate at the boundary.
        context.saveGState()
        if overlay.hasShadow {
            let shadowOffset = CGSize(
                width: CGFloat(overlay.shadowOffsetX),
                height: -CGFloat(overlay.shadowOffsetY)
            )
            context.setShadow(
                offset: shadowOffset,
                blur: 0,
                color: overlay.shadowColor.cgColor
            )
        }

        if overlay.gradientEnabled {
            drawGradientText(
                text: text,
                font: font,
                textRect: textRect,
                startColor: overlay.gradientStartColor.cgColor,
                endColor: overlay.gradientEndColor.cgColor,
                angleDegrees: overlay.gradientAngle,
                in: context
            )
        } else {
            drawSolidText(attrString: attrString, origin: origin, in: context)
        }

        context.restoreGState()
    } // draw

    /// Render the text overlay onto a transparent `CGImage` of the given canvas size.
    ///
    /// Primary use cases: testing, preview, and ad-hoc export. The frame-rendering
    /// pipeline should prefer `draw(in:...)` directly into the frame's context to
    /// avoid an extra bitmap allocation per frame.
    ///
    /// Returns `nil` if a bitmap context cannot be created (e.g. invalid dimensions).
    static func renderImage(
        overlay: TextOverlay,
        canvasWidth: Int,
        canvasHeight: Int
    ) -> CGImage? {
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        draw(overlay: overlay, in: context,
             canvasWidth: canvasWidth, canvasHeight: canvasHeight)
        return context.makeImage()
    } // renderImage

    // MARK: - Solid Color Drawing

    /// Draw a solid-color attributed string into the context at the given origin.
    /// Shadow (if any) is inherited from the context state set by the caller.
    private static func drawSolidText(
        attrString: NSAttributedString,
        origin: CGPoint,
        in context: CGContext
    ) {
        NSGraphicsContext.saveGraphicsState()
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.current = ns
        attrString.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    } // drawSolidText

    // MARK: - Gradient Drawing

    /// Draw gradient-filled text into the context using the "render to mask,
    /// clip, draw gradient" technique. Shadow (if any) is inherited from the
    /// context state set by the caller and applies to the filled gradient shape.
    private static func drawGradientText(
        text: String,
        font: CTFont,
        textRect: CGRect,
        startColor: CGColor,
        endColor: CGColor,
        angleDegrees: Double,
        in context: CGContext
    ) {
        let w = Int(ceil(textRect.width))
        let h = Int(ceil(textRect.height))
        guard w > 0, h > 0 else { return }

        // Build a mask bitmap: white text on transparent background.
        // Core Graphics uses the alpha channel as the clip mask.
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let maskContext = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return }

        // Draw opaque white text onto the mask bitmap
        let maskAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let maskString = NSAttributedString(string: text, attributes: maskAttrs)

        NSGraphicsContext.saveGraphicsState()
        let ns = NSGraphicsContext(cgContext: maskContext, flipped: false)
        NSGraphicsContext.current = ns
        maskString.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()

        guard let maskImage = maskContext.makeImage() else { return }

        // Clip the main context to the mask's alpha, then draw a linear gradient.
        // The clip is scoped to the textRect within the main context's coords.
        context.saveGState()
        context.clip(to: textRect, mask: maskImage)

        let (gradStart, gradEnd) = gradientEndpoints(
            rect: textRect,
            angleRadians: CGFloat(angleDegrees * .pi / 180.0)
        )

        if let gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [startColor, endColor] as CFArray,
            locations: [0.0, 1.0]
        ) {
            context.drawLinearGradient(
                gradient, start: gradStart, end: gradEnd, options: []
            )
        }
        context.restoreGState()
    } // drawGradientText

    // MARK: - Gradient Geometry

    /// Compute start/end points for a linear gradient spanning a rect along a
    /// given angle. Angle uses mathematical convention (0 = horizontal
    /// left-to-right, CCW positive), matching the Python port's gradient math.
    ///
    /// The span is chosen so the gradient covers the full rect for any angle
    /// via the classic "projected half-extents" formula also used by the Python.
    static func gradientEndpoints(
        rect: CGRect,
        angleRadians: CGFloat
    ) -> (start: CGPoint, end: CGPoint) {
        let cosA = cos(angleRadians)
        let sinA = sin(angleRadians)

        let cx = rect.midX
        let cy = rect.midY

        // Half-span of the rect projected onto the gradient direction
        let halfW = rect.width / 2
        let halfH = rect.height / 2
        let halfSpan = abs(cosA * halfW) + abs(sinA * halfH)

        let dx = cosA * halfSpan
        let dy = sinA * halfSpan

        return (
            start: CGPoint(x: cx - dx, y: cy - dy),
            end:   CGPoint(x: cx + dx, y: cy + dy)
        )
    } // gradientEndpoints
} // TextOverlayRenderer

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `TextOverlayRenderer`.
/// Call `TextOverlayRendererTests.runAll()` from a scratch entry point under `#if DEBUG`.
///
/// Note: full pixel-fidelity testing of CoreText output is impractical here.
/// These tests focus on structural guarantees (no crashes, correct dimensions,
/// non-empty output for non-empty input, geometry math correctness).
enum TextOverlayRendererTests {

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

        /// Check if a CGImage has at least one non-zero-alpha pixel, i.e.
        /// something was actually drawn. Scans a grid of sample points so we
        /// don't pay for a full image read.
        func hasAnyOpaquePixel(_ image: CGImage) -> Bool {
            guard let dataProvider = image.dataProvider,
                  let data = dataProvider.data,
                  let bytes = CFDataGetBytePtr(data) else { return false }
            let bpp = image.bitsPerPixel / 8
            let bpr = image.bytesPerRow
            let h = image.height
            let w = image.width
            // Sample on a coarse grid
            for y in stride(from: 0, to: h, by: max(1, h / 32)) {
                for x in stride(from: 0, to: w, by: max(1, w / 32)) {
                    let offset = y * bpr + x * bpp
                    // Premultiplied-last: alpha is the final byte in each pixel
                    let alpha = bytes[offset + bpp - 1]
                    if alpha > 0 { return true }
                }
            }
            return false
        } // hasAnyOpaquePixel

        /// Build a baseline TextOverlay for the given text / position / flags.
        func makeOverlay(
            text: String,
            x: Double = 0.5,
            y: Double = 0.5,
            gradient: Bool = false,
            shadow: Bool = false
        ) -> TextOverlay {
            TextOverlay(
                text: text,
                startTime: 0, endTime: 1,
                positionX: x, positionY: y,
                fontSize: 48,
                fontName: "Helvetica",
                isBold: false, isItalic: false,
                textColor: .white,
                hasShadow: shadow,
                shadowColor: .black,
                shadowOffsetX: 2, shadowOffsetY: 2,
                gradientEnabled: gradient,
                gradientStartColor: .white,
                gradientEndColor: CodableColor(red: 0, green: 0.5, blue: 1),
                gradientAngle: 45
            )
        } // makeOverlay

        // MARK: Empty / degenerate inputs

        let emptyImage = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: ""),
            canvasWidth: 400, canvasHeight: 200
        )
        check("empty text returns a valid empty canvas",
              emptyImage != nil && !hasAnyOpaquePixel(emptyImage!))

        let zeroCanvas = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: "Hi"),
            canvasWidth: 0, canvasHeight: 100
        )
        check("zero canvas width returns nil",
              zeroCanvas == nil)

        // MARK: Solid text

        let solidImage = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: "Hello World"),
            canvasWidth: 400, canvasHeight: 200
        )
        check("solid text renders a non-nil image",
              solidImage != nil)
        check("solid text image has expected canvas dimensions",
              solidImage?.width == 400 && solidImage?.height == 200)
        check("solid text image has visible drawn pixels",
              solidImage.map(hasAnyOpaquePixel) ?? false)

        // MARK: Gradient text

        let gradientImage = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: "Hello World", gradient: true),
            canvasWidth: 400, canvasHeight: 200
        )
        check("gradient text renders a non-nil image",
              gradientImage != nil)
        check("gradient text image has visible drawn pixels",
              gradientImage.map(hasAnyOpaquePixel) ?? false)

        // MARK: Shadow

        let shadowImage = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: "Shadowy", shadow: true),
            canvasWidth: 400, canvasHeight: 200
        )
        check("shadowed text renders a non-nil image",
              shadowImage != nil)
        check("shadowed text image has visible drawn pixels",
              shadowImage.map(hasAnyOpaquePixel) ?? false)

        // MARK: Gradient geometry

        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)

        let (start0, end0) = TextOverlayRenderer.gradientEndpoints(
            rect: rect, angleRadians: 0
        )
        // angle 0: start on left, end on right, both at vertical center
        check("gradient 0 deg starts at left edge",
              abs(start0.x - rect.minX) < 0.001 && abs(start0.y - rect.midY) < 0.001)
        check("gradient 0 deg ends at right edge",
              abs(end0.x - rect.maxX) < 0.001 && abs(end0.y - rect.midY) < 0.001)

        let (start90, end90) = TextOverlayRenderer.gradientEndpoints(
            rect: rect, angleRadians: .pi / 2
        )
        // angle 90: start at bottom, end at top (math convention, y up)
        check("gradient 90 deg starts at bottom edge",
              abs(start90.x - rect.midX) < 0.001 && abs(start90.y - rect.minY) < 0.001)
        check("gradient 90 deg ends at top edge",
              abs(end90.x - rect.midX) < 0.001 && abs(end90.y - rect.maxY) < 0.001)

        let (start180, end180) = TextOverlayRenderer.gradientEndpoints(
            rect: rect, angleRadians: .pi
        )
        // angle 180: start on right, end on left
        check("gradient 180 deg starts at right edge",
              abs(start180.x - rect.maxX) < 0.001 && abs(start180.y - rect.midY) < 0.001)
        check("gradient 180 deg ends at left edge",
              abs(end180.x - rect.minX) < 0.001 && abs(end180.y - rect.midY) < 0.001)

        // MARK: Position sanity

        // Text centered at (0.5, 0.5) on a large canvas should leave the
        // corner pixels transparent. This is a weak check but catches "text
        // fills entire canvas" regressions.
        let centered = TextOverlayRenderer.renderImage(
            overlay: makeOverlay(text: "X", x: 0.5, y: 0.5),
            canvasWidth: 800, canvasHeight: 600
        )
        if let img = centered,
           let data = img.dataProvider?.data,
           let bytes = CFDataGetBytePtr(data) {
            let bpp = img.bitsPerPixel / 8
            let bpr = img.bytesPerRow
            // Read corner pixel (0, 0) alpha
            let cornerAlpha = bytes[0 * bpr + 0 * bpp + (bpp - 1)]
            check("centered text leaves corner pixel transparent",
                  cornerAlpha == 0)
        } else {
            failed.append("centered text rendered nil image")
        }

        print("TextOverlayRendererTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // TextOverlayRendererTests

#endif
