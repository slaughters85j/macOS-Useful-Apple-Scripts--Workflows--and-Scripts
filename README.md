# macOS Useful Apple Scripts, Workflows, and Scripts

A comprehensive collection of macOS automation tools including AppleScripts, Automator workflows, and Python scripts designed to streamline various tasks related to audio processing, photo/video management, and system utilities. All applications and workflows are signed with an Apple Developer ID for trusted execution.

## 🚀 Quick Start

### AppleScripts
1. Open any `.applescript` file in **Script Editor** (Applications > Utilities > Script Editor)
2. Click **Build** or press `⌘+K` to compile the script
3. Click **Run** or press `⌘+R` to execute, or **Export** to save as an application

### Automator Workflows
All workflows are configured as **Quick Actions** for Finder:
1. Double-click any `.workflow` file to install it
2. Right-click on files/folders in Finder
3. Select the workflow from the **Quick Actions** menu

### Python Scripts
Ensure you have Python 3 and required dependencies installed:
```bash
pip install ffmpeg-python
```

## 📁 Project Structure

### Apple Scripts/

#### Audio/
- **`MP3 → M4A Converter (Fixed 30 s AAC-LC Mono 44.1 kHz @ 96 kbps).applescript`**
  - Converts MP3 files to 30-second M4A clips with uniform audio parameters
  - Perfect for creating alarm tones, notifications, or audio samples
  - Automatically handles trimming or padding to enforce exact 30.000s duration
  - Uses FFmpeg with AAC-LC codec, mono channel, 44.1 kHz sample rate, 96 kbps bitrate
  - **Requirements**: FFmpeg installed via Homebrew (`brew install ffmpeg`)

#### Photo & Video Management/

##### Video Processing Scripts
- **`Batch Video Organizer by Resolution.applescript`**
  - Automatically sorts videos into folders based on their resolution (e.g., 1920x1080, 3840x2160)
  - Uses ffprobe to analyze video dimensions
  - Creates subfolders and moves files accordingly
  - **Requirements**: FFmpeg/ffprobe installed


- **`Video CFR 15fps 2-Pass Encoder.app/`**
  - Drag-and-drop application for encoding videos to constant 15fps
  - Uses 2-pass encoding for optimal quality
  - Pre-built macOS application bundle

- **`Video Metadata Inspector (via FFmpeg).applescript`**
  - Quick Action to display video metadata including codec, FPS, bitrate, and resolution
  - Designed to work as a Finder Quick Action
  - **Requirements**: FFmpeg installed

##### Image Processing Scripts
- **`Batch_Rename_Photos.applescript`**
  - Renames all images in a folder with folder name prefix and sequential numbering
  - Format: `FolderName_000001.jpg`, `FolderName_000002.png`, etc.
  - Supports PNG, JPG, JPEG, TIFF, and GIF formats
  - Useful for preparing image datasets or organizing photo collections

- **`Batch_Rename_Videos.applescript`**
  - Similar to photo renamer but for video files
  - Supports MP4, MOV, AVI, MKV, M4V, FLV, and WMV formats
  - Sequential renaming with zero-padded numbering

- **`PNG Batch Resizer to 512x512.applescript`**
  - Batch resizes all PNG images in a directory to 512x512 pixels
  - Uses built-in macOS `sips` utility
  - Overwrites original files (destructive operation)
  - Perfect for creating uniform thumbnails or training data

##### Machine Learning & Annotation
- **`VOC XML Annotation Generator.applescript`**
  - Generates Pascal VOC-style XML annotation files for images
  - Creates bounding box annotations covering the entire image
  - Extracts person names from filename for labeling
  - Creates organized folder structure for training datasets
  - **Use case**: Preparing image datasets for computer vision projects

##### Utilities
- **`dimensions_diagnostic.applescript`**
  - Diagnostic script for analyzing image dimensions and properties

### Python/

#### Photo & Video Management/
- **`video_splitter.py`**
  - Interactive Python script for splitting videos into segments
  - Preserves original bit rate and resolution while allowing custom frame rates
  - Supports Apple Silicon hardware acceleration via VideoToolbox
  - Options to split by number of segments or duration per segment
  - **Requirements**: Python 3, ffmpeg-python library

### Automator Workflows/

#### System Utilities
- **`Delete DS Store File.workflow`**
  - Quick Action to remove .DS_Store files from selected folders
  - Helps clean up directories before sharing or version control
  - Recursively removes all .DS_Store files in the selected location

#### Media Processing
- **`Images to Video.workflow`**
  - Converts a sequence of images into a video file
  - Useful for creating time-lapse videos or slideshows
  - Quick Action for Finder integration

#### Development Tools
- **`Python Related/Open with Python.workflow`**
  - Quick Action to open Python files with the Python interpreter
  - Streamlines Python script execution from Finder
  - Configured for easy access via right-click menu

## 🔧 Requirements

### System Requirements
- macOS (tested on recent versions)
- Script Editor (included with macOS)
- Automator (included with macOS)

### External Dependencies
- **FFmpeg**: Required for video/audio processing scripts
  ```bash
  brew install ffmpeg
  ```
- **Python 3**: For Python scripts
  ```bash
  pip install ffmpeg-python  # For video_splitter.py
  ```

### Permissions
Some scripts require permissions for:
- File system access
- Running shell commands
- Accessing Finder for file operations

## 📖 Usage Instructions

### Running AppleScripts

1. **Direct Execution**:
   - Double-click `.applescript` files to open in Script Editor
   - Press `⌘+R` to run immediately

2. **Creating Applications**:
   - Open script in Script Editor
   - Go to File > Export
   - Choose "Application" as file format
   - Save to Applications folder or Desktop

3. **Creating Quick Actions**:
   - Open script in Script Editor
   - Go to File > Export
   - Choose "Quick Action" as file format
   - Configure input types and settings

### Installing Workflows

1. Double-click any `.workflow` file
2. Click "Install" when prompted
3. Access via Finder's right-click menu under "Quick Actions"

### Customization

Many scripts include configuration sections at the top:
- File format lists
- Directory paths
- Processing parameters
- Output settings

Edit these sections to match your specific needs.

## 🔐 Security & Trust

All applications and workflows in this repository are signed with an Apple Developer ID Application certificate, ensuring:
- Verified publisher identity
- Code integrity protection
- Gatekeeper compatibility
- Safe execution on macOS

## 🤝 Contributing

Feel free to:
- Report issues or bugs
- Suggest improvements
- Submit pull requests
- Share additional useful scripts

## 📝 License

This collection is provided as-is for educational and productivity purposes. Individual scripts may have their own requirements or limitations as noted in their headers.

## 💡 Tips

- Always backup important files before running batch operations
- Test scripts on sample data first
- Customize file paths and parameters to match your system
- Check FFmpeg installation paths if video scripts fail
- Some scripts may need permission adjustments in System Preferences > Security & Privacy

---

**Created to help automate common macOS tasks and improve productivity workflows.**
