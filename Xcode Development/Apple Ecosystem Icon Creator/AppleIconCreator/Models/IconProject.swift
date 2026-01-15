//
//  IconProject.swift
//  AppleIconCreator
//
//  Created by Apple Ecosystem Icon Creator
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Icon Project Model

@MainActor
class IconProject: ObservableObject {
    // Source image
    @Published var sourceImage: NSImage?
    @Published var sourceImageURL: URL?
    
    // Crop and positioning
    @Published var cropRect: CGRect = .zero
    @Published var scale: CGFloat = 1.0
    @Published var offset: CGSize = .zero
    
    // Edge overlap - extends source beyond icon boundary to ensure full coverage
    @Published var edgeOverlap: CGFloat = 0  // pixels to extend on each edge
    @Published var showOverlapGuide: Bool = true
    
    // Background fill for transparent images
    @Published var backgroundColor: Color = .white
    @Published var useBackgroundFill: Bool = false
    
    // Platform selections
    @Published var platforms: Set<Platform> = [.iOS, .macOS]
    
    // Export settings
    @Published var exportFolderURL: URL?
    @Published var createAssetCatalog: Bool = true
    @Published var flattenTransparency: Bool = false
    
    // Validation
    @Published var validationResults: [ValidationResult] = []
    @Published var hasTransparency: Bool = false
    @Published var isValidColorSpace: Bool = true
    @Published var sourceDimensions: CGSize = .zero
    
    // Export state
    @Published var isExporting: Bool = false
    @Published var exportProgress: Double = 0.0
    @Published var exportError: String?
    
    // MARK: - Computed Properties
    
    var isSourceValid: Bool {
        sourceImage != nil && sourceDimensions.width >= 1024 && sourceDimensions.height >= 1024
    }
    
    var allVariantsToExport: [IconVariant] {
        var variants: [IconVariant] = []
        
        for platform in platforms {
            switch platform {
            case .iOS:
                variants.append(contentsOf: iOSAppIconSize.allCases.flatMap { $0.variants })
            case .macOS:
                variants.append(contentsOf: MacAppIconSize.allCases.flatMap { $0.variants })
            case .watchOS:
                variants.append(contentsOf: WatchAppIconSize.allCases.flatMap { $0.variants })
            case .tvOS:
                variants.append(contentsOf: TVOSAppIconSize.allCases.flatMap { $0.variants })
            case .visionOS:
                variants.append(contentsOf: VisionOSAppIconSize.allCases.flatMap { $0.variants })
            }
        }
        
        return variants
    }
    
    var totalIconCount: Int {
        allVariantsToExport.count
    }
    
    // MARK: - Image Loading
    
    func loadImage(from url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            validationResults.append(ValidationResult(
                type: .error,
                message: "Failed to load image from \(url.lastPathComponent)"
            ))
            return
        }
        
        sourceImage = image
        sourceImageURL = url
        
        // Get actual pixel dimensions
        if let rep = image.representations.first {
            sourceDimensions = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        
        // Reset crop to full image
        cropRect = CGRect(origin: .zero, size: sourceDimensions)
        scale = 1.0
        offset = .zero
        
        // Validate the image
        validateSourceImage()
    }
    
    func loadImage(_ image: NSImage) {
        sourceImage = image
        sourceImageURL = nil
        
        if let rep = image.representations.first {
            sourceDimensions = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        
        cropRect = CGRect(origin: .zero, size: sourceDimensions)
        scale = 1.0
        offset = .zero
        
        validateSourceImage()
    }
    
    // MARK: - Validation
    
    func validateSourceImage() {
        validationResults.removeAll()
        
        guard let image = sourceImage else {
            validationResults.append(ValidationResult(
                type: .error,
                message: "No source image loaded"
            ))
            return
        }
        
        // Check dimensions
        if sourceDimensions.width < 1024 || sourceDimensions.height < 1024 {
            validationResults.append(ValidationResult(
                type: .error,
                message: "Source image must be at least 1024×1024 pixels. Current: \(Int(sourceDimensions.width))×\(Int(sourceDimensions.height))"
            ))
        }
        
        // Check if square
        if sourceDimensions.width != sourceDimensions.height {
            validationResults.append(ValidationResult(
                type: .warning,
                message: "Source image is not square (\(Int(sourceDimensions.width))×\(Int(sourceDimensions.height))). Will be cropped to center square."
            ))
        }
        
        // Check for transparency
        hasTransparency = checkForTransparency(in: image)
        if hasTransparency {
            validationResults.append(ValidationResult(
                type: .warning,
                message: "Image contains transparency. iOS requires fully opaque icons. Enable 'Flatten Transparency' to fill with background color."
            ))
        }
        
        // Check color space
        isValidColorSpace = checkColorSpace(in: image)
        if !isValidColorSpace {
            validationResults.append(ValidationResult(
                type: .warning,
                message: "Image may not be in sRGB or Display P3 color space. Icons should use RGB color model."
            ))
        }
        
        // Success message if no issues
        if validationResults.isEmpty {
            validationResults.append(ValidationResult(
                type: .success,
                message: "Source image is valid and ready for export"
            ))
        }
    }
    
    private func checkForTransparency(in image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return false
        }
        
        // Check if alpha channel exists
        let alphaInfo = cgImage.alphaInfo
        switch alphaInfo {
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        default:
            // Has alpha channel - check if any pixels are actually transparent
            return checkForTransparentPixels(in: cgImage)
        }
    }
    
    private func checkForTransparentPixels(in cgImage: CGImage) -> Bool {
        let width = cgImage.width
        let height = cgImage.height
        
        // Sample edges to check for transparency (corners and edge midpoints)
        guard let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        
        // Check corners
        let samplePoints = [
            (0, 0),
            (width - 1, 0),
            (0, height - 1),
            (width - 1, height - 1),
            (width / 2, 0),
            (width / 2, height - 1),
            (0, height / 2),
            (width - 1, height / 2)
        ]
        
        for (x, y) in samplePoints {
            let offset = y * bytesPerRow + x * bytesPerPixel
            // Assuming RGBA or ARGB format
            let alpha = bytesPerPixel == 4 ? bytes[offset + 3] : 255
            if alpha < 255 {
                return true
            }
        }
        
        return false
    }
    
    private func checkColorSpace(in image: NSImage) -> Bool {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = cgImage.colorSpace else {
            return false
        }
        
        let colorModel = colorSpace.model
        return colorModel == .rgb
    }
    
    // MARK: - Clear
    
    func clear() {
        sourceImage = nil
        sourceImageURL = nil
        cropRect = .zero
        scale = 1.0
        offset = .zero
        edgeOverlap = 0
        validationResults.removeAll()
        hasTransparency = false
        isValidColorSpace = true
        sourceDimensions = .zero
        exportProgress = 0.0
        exportError = nil
    }
}

// MARK: - Validation Result

struct ValidationResult: Identifiable {
    let id = UUID()
    let type: ValidationType
    let message: String
    
    enum ValidationType {
        case error
        case warning
        case success
        
        var icon: String {
            switch self {
            case .error: return "xmark.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .error: return .red
            case .warning: return .orange
            case .success: return .green
            }
        }
    }
}
