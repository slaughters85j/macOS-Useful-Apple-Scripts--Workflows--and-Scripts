//
//  IconExporter.swift
//  AppleIconCreator
//
//  Created by Apple Ecosystem Icon Creator
//

import Foundation
import AppKit
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Export Settings (Thread-safe copy of project settings)

struct ExportSettings {
    let sourceImage: NSImage
    let sourceDimensions: CGSize
    let variants: [IconVariant]
    let flattenTransparency: Bool
    let backgroundColor: NSColor
    let createAssetCatalog: Bool
    let scale: CGFloat
    let offset: CGSize
    let edgeOverlap: CGFloat  // pixels to extend beyond icon edge
}

// MARK: - Icon Exporter

class IconExporter {
    
    // MARK: - Export All Icons
    
    static func exportIcons(
        from project: IconProject,
        to destinationURL: URL,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        print("📦 IconExporter.exportIcons called")
        print("   - destinationURL: \(destinationURL.path)")
        
        // Capture all needed values on main actor before going off-thread
        let settings = await MainActor.run {
            print("📦 Capturing settings on MainActor...")
            let s = ExportSettings(
                sourceImage: project.sourceImage!,
                sourceDimensions: project.sourceDimensions,
                variants: project.allVariantsToExport,
                flattenTransparency: project.flattenTransparency,
                backgroundColor: NSColor(project.backgroundColor),
                createAssetCatalog: project.createAssetCatalog,
                scale: project.scale,
                offset: project.offset,
                edgeOverlap: project.edgeOverlap
            )
            print("   - variants count: \(s.variants.count)")
            print("   - flattenTransparency: \(s.flattenTransparency)")
            return s
        }
        
        guard !settings.variants.isEmpty else {
            print("📦 🔴 No platforms selected!")
            throw ExportError.noPlatformsSelected
        }
        
        // Create destination directory
        print("📦 Creating directory: \(destinationURL.path)")
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        // Process and export each variant
        for (index, variant) in settings.variants.enumerated() {
            let progress = Double(index) / Double(settings.variants.count)
            await MainActor.run { progressHandler(progress) }
            
            let outputURL = destinationURL.appendingPathComponent(variant.filename)
            print("📦 Exporting [\(index + 1)/\(settings.variants.count)]: \(variant.filename)")
            
            try exportSingleIcon(
                to: outputURL,
                size: variant.size,
                settings: settings
            )
        }
        
        // Generate Contents.json if requested
        if settings.createAssetCatalog {
            print("📦 Generating Contents.json...")
            try generateContentsJSON(for: settings.variants, at: destinationURL)
        }
        
        print("📦 ✅ Export complete!")
        await MainActor.run { progressHandler(1.0) }
    }
    
    // MARK: - Export Single Icon
    
    private static func exportSingleIcon(
        to url: URL,
        size: CGSize,
        settings: ExportSettings
    ) throws {
        guard let cgImage = settings.sourceImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ExportError.invalidSourceImage
        }
        
        let targetWidth = Int(size.width)
        let targetHeight = Int(size.height)
        
        // Create bitmap context with sRGB color space
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportError.contextCreationFailed
        }
        
        // Always use premultiplied alpha for transparency support
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ExportError.contextCreationFailed
        }
        
        // The context starts with all zeros (fully transparent)
        // This is the key - anything not drawn stays transparent
        
        // Fill with background color if user wants to flatten transparency
        if settings.flattenTransparency {
            let cgColor = settings.backgroundColor.cgColor
            context.setFillColor(cgColor)
            context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        }
        
        // IMPORTANT: Clip to the target bounds BEFORE drawing
        // This ensures nothing renders outside the icon area
        context.clip(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        // Set high quality interpolation
        context.interpolationQuality = .high
        
        // Calculate draw rect
        let drawRect = calculateDrawRect(
            sourceSize: CGSize(width: cgImage.width, height: cgImage.height),
            targetSize: size,
            settings: settings
        )
        
        // Draw the image (will be clipped to target bounds)
        context.draw(cgImage, in: drawRect)
        
        // Create output image
        guard let outputCGImage = context.makeImage() else {
            throw ExportError.imageCreationFailed
        }
        
        // Write to PNG
        try writePNG(cgImage: outputCGImage, to: url)
    }
    
    // MARK: - Calculate Draw Rect
    
    private static func calculateDrawRect(
        sourceSize: CGSize,
        targetSize: CGSize,
        settings: ExportSettings
    ) -> CGRect {
        // Calculate the scale ratio from source (1024) to target
        // We want the source to fill the target completely (aspect fill)
        
        let sourceAspect = sourceSize.width / sourceSize.height
        let targetAspect = targetSize.width / targetSize.height
        
        var drawWidth: CGFloat
        var drawHeight: CGFloat
        
        if sourceAspect > targetAspect {
            // Source is wider - fit height, let width overflow
            drawHeight = targetSize.height
            drawWidth = targetSize.height * sourceAspect
        } else {
            // Source is taller or equal - fit width, let height overflow
            drawWidth = targetSize.width
            drawHeight = targetSize.width / sourceAspect
        }
        
        // Apply edge overlap - this expands the drawn image beyond the target bounds
        // The overlap is specified in pixels at 1024x1024 scale, so we need to scale it
        let overlapScale = targetSize.width / 1024.0
        let scaledOverlap = settings.edgeOverlap * overlapScale
        
        // Expand the draw size by overlap on all sides
        drawWidth += scaledOverlap * 2
        drawHeight += scaledOverlap * 2
        
        // Apply user scale (centered)
        drawWidth *= settings.scale
        drawHeight *= settings.scale
        
        // Center the image in the target
        let xOffset = (targetSize.width - drawWidth) / 2
        let yOffset = (targetSize.height - drawHeight) / 2
        
        // Apply user offset (scaled to target size)
        let scaledOffsetX = settings.offset.width * overlapScale
        let scaledOffsetY = settings.offset.height * overlapScale
        
        return CGRect(
            x: xOffset + scaledOffsetX,
            y: yOffset + scaledOffsetY,
            width: drawWidth,
            height: drawHeight
        )
    }
    
    // MARK: - Write PNG
    
    private static func writePNG(cgImage: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.destinationCreationFailed
        }
        
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGCompressionFilter: 5
        ]
        
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.writeFailed
        }
    }
    
    // MARK: - Generate Contents.json
    
    private static func generateContentsJSON(for variants: [IconVariant], at url: URL) throws {
        var images: [[String: Any]] = []
        
        for variant in variants {
            var imageDict: [String: Any] = [
                "filename": variant.filename,
                "idiom": variant.idiom,
                "scale": "\(variant.scale)x"
            ]
            
            // Add size for iOS/macOS
            if variant.platform == .iOS || variant.platform == .macOS {
                let pointSize = Double(variant.pixelWidth) / Double(variant.scale)
                if pointSize == 83.5 {
                    imageDict["size"] = "83.5x83.5"
                } else {
                    imageDict["size"] = "\(Int(pointSize))x\(Int(pointSize))"
                }
            }
            
            images.append(imageDict)
        }
        
        let contents: [String: Any] = [
            "images": images,
            "info": [
                "author": "Apple Ecosystem Icon Creator",
                "version": 1
            ]
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
        let contentsURL = url.appendingPathComponent("Contents.json")
        try jsonData.write(to: contentsURL)
    }
}

// MARK: - Export Errors

enum ExportError: LocalizedError {
    case noSourceImage
    case noPlatformsSelected
    case invalidSourceImage
    case contextCreationFailed
    case imageCreationFailed
    case destinationCreationFailed
    case writeFailed
    case exportCancelled
    
    var errorDescription: String? {
        switch self {
        case .noSourceImage:
            return "No source image loaded"
        case .noPlatformsSelected:
            return "No platforms selected for export"
        case .invalidSourceImage:
            return "Source image is invalid or corrupted"
        case .contextCreationFailed:
            return "Failed to create graphics context"
        case .imageCreationFailed:
            return "Failed to create output image"
        case .destinationCreationFailed:
            return "Failed to create output file"
        case .writeFailed:
            return "Failed to write PNG file"
        case .exportCancelled:
            return "Export was cancelled"
        }
    }
}
