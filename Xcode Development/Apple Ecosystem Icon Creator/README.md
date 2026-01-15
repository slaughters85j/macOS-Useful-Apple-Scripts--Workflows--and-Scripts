# Apple Ecosystem Icon Creator

A macOS SwiftUI app for generating app icons for all Apple platforms from a single source image.

## Features

- **Drag & Drop** - Simply drop your source image (PNG or JPEG, 1024×1024 minimum)
- **Multi-Platform Export** - Generate icons for iOS, macOS, watchOS, tvOS, and visionOS
- **Live Preview** - See how your icon will look with the iOS squircle mask
- **Transparency Handling** - Automatically flatten transparency with configurable background color (iOS requirement)
- **Validation** - Warns about common issues (transparency, wrong dimensions, color space)
- **Asset Catalog Ready** - Exports with `Contents.json` ready to drop into Xcode
- **Scale & Position** - Fine-tune your icon's position within the safe area

## Supported Icon Sizes

### iOS / iPadOS
| Size (pt) | Scales | Usage |
|-----------|--------|-------|
| 20 | @2x, @3x | Notification (iPad) |
| 29 | @2x, @3x | Settings |
| 38 | @2x, @3x | Home Screen (Small) |
| 40 | @2x, @3x | Spotlight |
| 60 | @2x, @3x | Home Screen (iPhone) |
| 64 | @2x, @3x | Home Screen |
| 68 | @2x, @3x | Home Screen (iPad) |
| 76 | @2x, @3x | Home Screen (iPad) |
| 83.5 | @2x | Home Screen (iPad Pro) |
| 1024 | @1x | App Store |

### macOS
| Size (pt) | Scales | Usage |
|-----------|--------|-------|
| 16 | @1x, @2x | Finder, Spotlight |
| 32 | @1x, @2x | Finder, Dock |
| 128 | @1x, @2x | Finder |
| 256 | @1x, @2x | Finder |
| 512 | @1x, @2x | Finder, App Store |

### watchOS
| Size (pt) | Scales | Usage |
|-----------|--------|-------|
| 40 | @2x | 38mm Home Screen |
| 44 | @2x | 42mm Home Screen |
| 48 | @2x | 44mm+ Home Screen |
| 86 | @2x | Short Look Notification |
| 1024 | @1x | App Store |

### tvOS
| Size (px) | Usage |
|-----------|-------|
| 400×240, 800×480 | Home Screen |
| 1280×768 | App Store |

### visionOS
| Size (px) | Usage |
|-----------|-------|
| 1024×1024 | App Icon |

## Requirements

- macOS 14.0 (Sonoma) or later
- Source image: PNG or JPEG, minimum 1024×1024 pixels, square recommended

## Usage

1. Launch the app
2. Drag and drop your source image (or click "Choose File...")
3. Adjust scale and position if needed
4. Select target platforms
5. Configure transparency handling (enable "Flatten transparency" for iOS)
6. Click "Export Icons"
7. Choose destination folder
8. Copy the generated `AppIcon.appiconset` folder to your Xcode project's Assets.xcassets

## Important Notes

### iOS Icon Requirements
- **No transparency**: iOS icons must be fully opaque. Enable "Flatten transparency" to fill transparent areas with your chosen background color.
- **No rounded corners**: Don't round your icon corners - iOS applies the squircle mask automatically.
- **sRGB or Display P3**: Use RGB color space for compatibility.

### Why This Exists
After spending an hour debugging why iOS was showing white borders on app icons (turned out to be a 1-pixel transparent edge from a source image that wasn't exactly 1024×1024), I built this tool to:
1. Validate source images before export
2. Properly handle transparency
3. Generate all required sizes in one click
4. Produce Asset Catalog-ready output

## Building

Open `AppleIconCreator.xcodeproj` in Xcode 15+ and build.

## License

MIT License - Use freely for personal and commercial projects.
