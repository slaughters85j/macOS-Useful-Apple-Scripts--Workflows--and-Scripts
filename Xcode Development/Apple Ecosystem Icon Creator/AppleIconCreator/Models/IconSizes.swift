//
//  IconSizes.swift
//  AppleIconCreator
//
//  Created by Apple Ecosystem Icon Creator
//

import Foundation
import CoreGraphics

// MARK: - Platform Enumeration

enum Platform: String, CaseIterable, Identifiable {
    case iOS = "iOS"
    case macOS = "macOS"
    case watchOS = "watchOS"
    case tvOS = "tvOS"
    case visionOS = "visionOS"
    
    var id: String { rawValue }
    
    var displayName: String { rawValue }
    
    var iconPrefix: String {
        switch self {
        case .iOS: return "icon"
        case .macOS: return "icon"
        case .watchOS: return "watch-icon"
        case .tvOS: return "tv-icon"
        case .visionOS: return "vision-icon"
        }
    }
}

// MARK: - iOS App Icon Sizes

enum iOSAppIconSize: CaseIterable, Identifiable {
    case pt20
    case pt29
    case pt38
    case pt40
    case pt60
    case pt64
    case pt68
    case pt76
    case pt83_5
    case pt1024
    
    var id: String { "\(points)" }
    
    /// Base point size
    var points: CGFloat {
        switch self {
        case .pt20:     return 20
        case .pt29:     return 29
        case .pt38:     return 38
        case .pt40:     return 40
        case .pt60:     return 60
        case .pt64:     return 64
        case .pt68:     return 68
        case .pt76:     return 76
        case .pt83_5:   return 83.5
        case .pt1024:   return 1024
        }
    }
    
    /// Supported scale factors for this icon size
    var scales: [Int] {
        switch self {
        case .pt1024:
            return [1]        // App Store only
        default:
            return [2, 3]     // Standard Retina variants
        }
    }
    
    /// Pixel dimensions for all required renditions
    var pixelSizes: [CGSize] {
        scales.map {
            CGSize(
                width: points * CGFloat($0),
                height: points * CGFloat($0)
            )
        }
    }
    
    /// Usage description
    var usage: String {
        switch self {
        case .pt20:     return "Notification (iPad)"
        case .pt29:     return "Settings"
        case .pt38:     return "Home Screen (Small)"
        case .pt40:     return "Spotlight"
        case .pt60:     return "Home Screen (iPhone)"
        case .pt64:     return "Home Screen"
        case .pt68:     return "Home Screen (iPad)"
        case .pt76:     return "Home Screen (iPad)"
        case .pt83_5:   return "Home Screen (iPad Pro)"
        case .pt1024:   return "App Store"
        }
    }
    
    /// Generate all icon variants with filenames
    var variants: [IconVariant] {
        scales.map { scale in
            let pixelSize = Int(points * CGFloat(scale))
            let filename: String
            if points == 83.5 {
                filename = "icon-83.5x83.5@\(scale)x.png"
            } else {
                filename = "icon-\(Int(points))x\(Int(points))@\(scale)x.png"
            }
            return IconVariant(
                filename: filename,
                size: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize)),
                scale: scale,
                platform: .iOS,
                idiom: idiom(for: scale)
            )
        }
    }
    
    private func idiom(for scale: Int) -> String {
        switch self {
        case .pt76, .pt83_5, .pt68:
            return "ipad"
        case .pt1024:
            return "ios-marketing"
        default:
            return scale == 3 ? "iphone" : "universal"
        }
    }
}

// MARK: - macOS App Icon Sizes

enum MacAppIconSize: CaseIterable, Identifiable {
    case pt16
    case pt32
    case pt128
    case pt256
    case pt512
    
    var id: String { "\(points)" }
    
    /// Base point size
    var points: CGFloat {
        switch self {
        case .pt16:   return 16
        case .pt32:   return 32
        case .pt128:  return 128
        case .pt256:  return 256
        case .pt512:  return 512
        }
    }
    
    /// Supported scale factors for this icon size
    var scales: [Int] {
        [1, 2]   // Standard macOS @1x / @2x
    }
    
    /// Pixel dimensions for all required renditions
    var pixelSizes: [CGSize] {
        scales.map {
            CGSize(
                width: points * CGFloat($0),
                height: points * CGFloat($0)
            )
        }
    }
    
    /// Usage description
    var usage: String {
        switch self {
        case .pt16:   return "Finder, Spotlight"
        case .pt32:   return "Finder, Dock"
        case .pt128:  return "Finder"
        case .pt256:  return "Finder"
        case .pt512:  return "Finder, App Store"
        }
    }
    
    /// Generate all icon variants with filenames
    var variants: [IconVariant] {
        scales.map { scale in
            let pixelSize = Int(points * CGFloat(scale))
            let scaleStr = scale == 1 ? "" : "@\(scale)x"
            let filename = "icon_\(Int(points))x\(Int(points))\(scaleStr).png"
            return IconVariant(
                filename: filename,
                size: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize)),
                scale: scale,
                platform: .macOS,
                idiom: "mac"
            )
        }
    }
}

// MARK: - watchOS App Icon Sizes

enum WatchAppIconSize: CaseIterable, Identifiable {
    case appLauncher40
    case appLauncher44
    case appLauncher48
    case shortLook
    case notification
    case appStore
    
    var id: String { "\(basePoints)" }
    
    /// Pixel base @1x points
    var basePoints: CGFloat {
        switch self {
        case .appLauncher40:   return 40
        case .appLauncher44:   return 44
        case .appLauncher48:   return 48
        case .shortLook:       return 86
        case .notification:    return 48
        case .appStore:        return 1024
        }
    }
    
    /// Supported scale (@2x standard watchOS)
    var scales: [Int] {
        switch self {
        case .appStore:
            return [1]
        default:
            return [2]
        }
    }
    
    var pixelSizes: [CGSize] {
        scales.map { scale in
            let p = basePoints * CGFloat(scale)
            return CGSize(width: p, height: p)
        }
    }
    
    /// Usage description
    var usage: String {
        switch self {
        case .appLauncher40:   return "38mm Home Screen"
        case .appLauncher44:   return "42mm Home Screen"
        case .appLauncher48:   return "44mm+ Home Screen"
        case .shortLook:       return "Short Look Notification"
        case .notification:    return "Notification Center"
        case .appStore:        return "App Store"
        }
    }
    
    /// Generate all icon variants with filenames
    var variants: [IconVariant] {
        scales.map { scale in
            let pixelSize = Int(basePoints * CGFloat(scale))
            let filename = "watch-icon-\(Int(basePoints))@\(scale)x.png"
            return IconVariant(
                filename: filename,
                size: CGSize(width: CGFloat(pixelSize), height: CGFloat(pixelSize)),
                scale: scale,
                platform: .watchOS,
                idiom: "watch"
            )
        }
    }
}

// MARK: - tvOS App Icon Sizes

enum TVOSAppIconSize: CaseIterable, Identifiable {
    /// Home screen launcher icon (@1x / @2x)
    case home
    /// App Store large icon
    case appStore
    
    var id: String {
        switch self {
        case .home: return "home"
        case .appStore: return "appStore"
        }
    }
    
    var pixelSize: CGSize {
        switch self {
        case .home:
            // tvOS Home icon: 400×240 pt @1x
            return CGSize(width: 400, height: 240)
        case .appStore:
            // tvOS App Store artwork: 1280×768 px
            return CGSize(width: 1280, height: 768)
        }
    }
    
    /// Supported scales (tvOS only uses 1x and 2x)
    var scales: [Int] {
        switch self {
        case .home:
            return [1, 2]
        case .appStore:
            return [1]
        }
    }
    
    /// All concrete pixel variants
    var concreteSizes: [CGSize] {
        scales.map { scale in
            CGSize(
                width: pixelSize.width * CGFloat(scale),
                height: pixelSize.height * CGFloat(scale)
            )
        }
    }
    
    /// Usage description
    var usage: String {
        switch self {
        case .home: return "Home Screen"
        case .appStore: return "App Store"
        }
    }
    
    /// Generate all icon variants with filenames
    var variants: [IconVariant] {
        zip(scales, concreteSizes).map { scale, size in
            let filename = "tv-icon-\(Int(size.width))x\(Int(size.height)).png"
            return IconVariant(
                filename: filename,
                size: size,
                scale: scale,
                platform: .tvOS,
                idiom: "tv"
            )
        }
    }
}

// MARK: - visionOS App Icon Sizes

enum VisionOSAppIconSize: CaseIterable, Identifiable {
    case base1024
    
    var id: String { "1024" }
    
    var pixels: CGSize {
        CGSize(width: 1024, height: 1024)
    }
    
    var scales: [Int] { [1] }
    
    /// Usage description
    var usage: String { "App Icon" }
    
    /// Generate all icon variants with filenames
    var variants: [IconVariant] {
        [IconVariant(
            filename: "vision-icon-1024x1024.png",
            size: pixels,
            scale: 1,
            platform: .visionOS,
            idiom: "reality"
        )]
    }
}

// MARK: - Icon Variant (Unified Output Type)

struct IconVariant: Identifiable, Hashable {
    let id = UUID()
    let filename: String
    let size: CGSize
    let scale: Int
    let platform: Platform
    let idiom: String
    
    var pixelWidth: Int { Int(size.width) }
    var pixelHeight: Int { Int(size.height) }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(filename)
        hasher.combine(platform)
    }
    
    static func == (lhs: IconVariant, rhs: IconVariant) -> Bool {
        lhs.filename == rhs.filename && lhs.platform == rhs.platform
    }
}
