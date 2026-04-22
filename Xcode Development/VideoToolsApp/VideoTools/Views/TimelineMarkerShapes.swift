import SwiftUI

// MARK: - Trim Marker Shape (Yellow tab + line style)

/// Shape used for the yellow trim start/end markers on the timeline.
/// Draws a rounded tab at the top with a vertical line extending downward.
struct TrimMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lineWidth: CGFloat = 2
        let tabHeight: CGFloat = 12
        let tabWidth: CGFloat = rect.width
        let centerX = rect.midX

        // Tab at top (rounded rectangle)
        let tabRect = CGRect(
            x: centerX - tabWidth / 2,
            y: rect.minY,
            width: tabWidth,
            height: tabHeight
        )
        path.addRoundedRect(in: tabRect, cornerSize: CGSize(width: 3, height: 3))

        // Vertical line from tab to bottom
        let lineRect = CGRect(
            x: centerX - lineWidth / 2,
            y: rect.minY + tabHeight - 2,
            width: lineWidth,
            height: rect.height - tabHeight + 2
        )
        path.addRect(lineRect)

        return path
    }
}

// MARK: - Cut Marker Shape

/// Shape used for the green (start) and red (end) cut segment markers.
/// Same visual as TrimMarkerShape — a rounded tab at top with a vertical line.
struct CutMarkerShape: Shape {
    let isStart: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lineWidth: CGFloat = 2
        let tabHeight: CGFloat = 12
        let tabWidth: CGFloat = rect.width
        let centerX = rect.midX

        // Tab at top (rounded rectangle)
        let tabRect = CGRect(
            x: centerX - tabWidth / 2,
            y: rect.minY,
            width: tabWidth,
            height: tabHeight
        )
        path.addRoundedRect(in: tabRect, cornerSize: CGSize(width: 3, height: 3))

        // Vertical line from tab to bottom
        let lineRect = CGRect(
            x: centerX - lineWidth / 2,
            y: rect.minY + tabHeight - 2,
            width: lineWidth,
            height: rect.height - tabHeight + 2
        )
        path.addRect(lineRect)

        return path
    }
}

// MARK: - Text Marker Shape

/// Shape used for the cyan text overlay timing markers.
/// Draws a rounded tab at the BOTTOM with a vertical line extending upward,
/// visually distinguishing text markers from trim/cut markers (which have tabs at top).
struct TextMarkerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let lineWidth: CGFloat = 2
        let tabHeight: CGFloat = 12
        let tabWidth: CGFloat = rect.width
        let centerX = rect.midX

        // Vertical line from top to above tab
        let lineRect = CGRect(
            x: centerX - lineWidth / 2,
            y: rect.minY,
            width: lineWidth,
            height: rect.height - tabHeight + 2
        )
        path.addRect(lineRect)

        // Tab at bottom (rounded rectangle)
        let tabRect = CGRect(
            x: centerX - tabWidth / 2,
            y: rect.maxY - tabHeight,
            width: tabWidth,
            height: tabHeight
        )
        path.addRoundedRect(in: tabRect, cornerSize: CGSize(width: 3, height: 3))

        return path
    }
}
