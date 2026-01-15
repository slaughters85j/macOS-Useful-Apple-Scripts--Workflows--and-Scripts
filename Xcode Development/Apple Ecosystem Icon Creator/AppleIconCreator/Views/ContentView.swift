//
//  ContentView.swift
//  AppleIconCreator
//
//  Created by Apple Ecosystem Icon Creator
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var project = IconProject()
    @State private var isDragging = false
    @State private var showingExportPanel = false
    
    var body: some View {
        HSplitView {
            // Left Panel - Source Image and Preview
            sourcePanel
                .frame(minWidth: 400)
            
            // Right Panel - Settings and Export
            settingsPanel
                .frame(minWidth: 300, maxWidth: 400)
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    // MARK: - Source Panel
    
    private var sourcePanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Source Image")
                    .font(.headline)
                Spacer()
                if project.sourceImage != nil {
                    Button("Clear") {
                        project.clear()
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            // Drop zone / Preview
            if let image = project.sourceImage {
                imagePreview(image)
            } else {
                dropZone
            }
            
            // Validation Messages
            if !project.validationResults.isEmpty {
                validationSection
            }
        }
    }
    
    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDragging ? Color.accentColor : Color.gray.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDragging ? Color.accentColor.opacity(0.1) : Color.clear)
                )
            
            VStack(spacing: 16) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                
                Text("Drop image here")
                    .font(.title2)
                    .foregroundColor(.secondary)
                
                Text("or")
                    .foregroundColor(.secondary)
                
                Button("Choose File...") {
                    openFilePicker()
                }
                .buttonStyle(.borderedProminent)
                
                Text("PNG or JPEG, minimum 1024×1024")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
            handleDrop(providers: providers)
        }
    }
    
    private func imagePreview(_ image: NSImage) -> some View {
        VStack(spacing: 0) {
            // Preview with iOS squircle mask overlay
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height) - 40
                let cornerRadius = size * 0.2237
                // Calculate overlap in preview coordinates
                let overlapPreview = project.edgeOverlap > 0 ? (project.edgeOverlap / 1024.0) * size : 0
                
                ZStack {
                    // Checkered background for transparency
                    CheckerboardView()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                    
                    // Source image (clipped to icon bounds)
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size + (overlapPreview * 2), height: size + (overlapPreview * 2))
                        .scaleEffect(project.scale)
                        .offset(project.offset)
                        .frame(width: size, height: size)
                        .clipped()
                    
                    // iOS squircle mask outline
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 2)
                        .frame(width: size, height: size)
                    
                    // Show overlap guide if enabled
                    if project.showOverlapGuide && project.edgeOverlap > 0 {
                        RoundedRectangle(cornerRadius: cornerRadius * (size - overlapPreview * 2) / size)
                            .strokeBorder(Color.red.opacity(0.7), lineWidth: 1)
                            .frame(width: size - overlapPreview * 2, height: size - overlapPreview * 2)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            // Scale and offset controls
            VStack(spacing: 12) {
                // Scale with preset button
                HStack {
                    Text("Scale")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $project.scale, in: 0.5...2.0)
                    Text("\(Int(project.scale * 100))%")
                        .frame(width: 50)
                    Button("100%") {
                        project.scale = 1.0
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                HStack {
                    Text("Offset X")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $project.offset.width, in: -200...200)
                    Text("\(Int(project.offset.width))")
                        .frame(width: 50)
                }
                
                HStack {
                    Text("Offset Y")
                        .frame(width: 60, alignment: .leading)
                    Slider(value: $project.offset.height, in: -200...200)
                    Text("\(Int(project.offset.height))")
                        .frame(width: 50)
                }
                
                HStack {
                    Button("Reset All") {
                        project.scale = 1.0
                        project.offset = .zero
                        project.edgeOverlap = 0
                    }
                    .buttonStyle(.borderless)
                    
                    Spacer()
                    
                    Button("Center") {
                        project.offset = .zero
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
        }
    }
    
    private var validationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(project.validationResults) { result in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: result.type.icon)
                        .foregroundColor(result.type.color)
                    Text(result.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
    }
    
    // MARK: - Settings Panel
    
    private var settingsPanel: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Export Settings")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Platform Selection
                    platformSection
                    
                    Divider()
                    
                    // Edge Overlap Settings
                    edgeOverlapSection
                    
                    Divider()
                    
                    // Background Settings
                    backgroundSection
                    
                    Divider()
                    
                    // Export Options
                    exportOptionsSection
                    
                    Divider()
                    
                    // Summary
                    summarySection
                }
                .padding()
            }
            
            Divider()
            
            // Export Button
            exportButton
        }
    }
    
    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Platforms")
                .font(.subheadline)
                .fontWeight(.medium)
            
            ForEach(Platform.allCases) { platform in
                Toggle(isOn: Binding(
                    get: { project.platforms.contains(platform) },
                    set: { isOn in
                        if isOn {
                            project.platforms.insert(platform)
                        } else {
                            project.platforms.remove(platform)
                        }
                    }
                )) {
                    HStack {
                        platformIcon(for: platform)
                        Text(platform.displayName)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }
    
    private func platformIcon(for platform: Platform) -> some View {
        let iconName: String
        switch platform {
        case .iOS: iconName = "iphone"
        case .macOS: iconName = "desktopcomputer"
        case .watchOS: iconName = "applewatch"
        case .tvOS: iconName = "appletv"
        case .visionOS: iconName = "visionpro"
        }
        return Image(systemName: iconName)
            .frame(width: 20)
    }
    
    private var edgeOverlapSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edge Overlap")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Toggle("Extend edges beyond mask", isOn: Binding(
                get: { project.edgeOverlap > 0 },
                set: { isOn in
                    project.edgeOverlap = isOn ? 4 : 0
                }
            ))
            .toggleStyle(.checkbox)
            
            if project.edgeOverlap > 0 {
                // Bind Int UI controls to CGFloat model value
                let edgeOverlapInt = Binding<Int>(
                    get: { Int(project.edgeOverlap.rounded()) },
                    set: { project.edgeOverlap = CGFloat($0) }
                )
                
                HStack {
                    Text("Overlap (px)")
                    Spacer()
                    TextField("", value: edgeOverlapInt, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                    Stepper("", value: edgeOverlapInt, in: 1...20)
                        .labelsHidden()
                }
                
                Toggle("Show overlap guide in preview", isOn: $project.showOverlapGuide)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                
                Text("Extends the source image beyond the icon boundary by \(Int(project.edgeOverlap))px on each edge to ensure full coverage after iOS applies the squircle mask.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var backgroundSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Background")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Text("Icons export with transparent background by default.")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Toggle("Fill background with solid color", isOn: $project.flattenTransparency)
                .toggleStyle(.checkbox)
            
            if project.flattenTransparency {
                HStack {
                    Text("Background Color")
                    Spacer()
                    ColorPicker("", selection: $project.backgroundColor)
                        .labelsHidden()
                }
            }
        }
    }
    
    private var exportOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export Options")
                .font(.subheadline)
                .fontWeight(.medium)
            
            Toggle("Generate Contents.json (Asset Catalog)", isOn: $project.createAssetCatalog)
                .toggleStyle(.checkbox)
        }
    }
    
    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Summary")
                .font(.subheadline)
                .fontWeight(.medium)
            
            HStack {
                Text("Total icons to export:")
                Spacer()
                Text("\(project.totalIconCount)")
                    .fontWeight(.medium)
            }
            .font(.caption)
            
            if !project.platforms.isEmpty {
                Text("Platforms: \(project.platforms.map { $0.displayName }.sorted().joined(separator: ", "))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var exportButton: some View {
        VStack(spacing: 8) {
            if project.isExporting {
                ProgressView(value: project.exportProgress) {
                    Text("Exporting... \(Int(project.exportProgress * 100))%")
                        .font(.caption)
                }
                .padding(.horizontal)
            }
            
            Button(action: startExport) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export Icons")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!project.isSourceValid || project.platforms.isEmpty || project.isExporting)
            .padding()
            
            if let error = project.exportError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal)
            }
        }
    }
    
    // MARK: - Actions
    
    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        
        if panel.runModal() == .OK, let url = panel.url {
            project.loadImage(from: url)
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        // Handle file URL drops (most common from Finder)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                guard let url = url, error == nil else { return }
                
                // Verify it's an image file
                let validExtensions = ["png", "jpg", "jpeg", "PNG", "JPG", "JPEG"]
                guard validExtensions.contains(url.pathExtension) else { return }
                
                DispatchQueue.main.async {
                    self.project.loadImage(from: url)
                }
            }
            return true
        }
        
        return false
    }
    
    private func startExport() {
        print("🟡 Export button clicked")
        print("   - isSourceValid: \(project.isSourceValid)")
        print("   - platforms: \(project.platforms)")
        print("   - isExporting: \(project.isExporting)")
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder to export the icon set"
        
        let response = panel.runModal()
        print("🟡 Panel response: \(response == .OK ? "OK" : "Cancel")")
        
        guard response == .OK, let url = panel.url else {
            print("🔴 No folder selected or panel cancelled")
            return
        }
        
        let exportURL = url.appendingPathComponent("AppIcon.appiconset")
        print("🟡 Export URL: \(exportURL.path)")
        
        project.isExporting = true
        project.exportError = nil
        
        Task {
            do {
                print("🟡 Starting IconExporter.exportIcons...")
                try await IconExporter.exportIcons(
                    from: project,
                    to: exportURL,
                    progressHandler: { progress in
                        print("🟡 Export progress: \(Int(progress * 100))%")
                        project.exportProgress = progress
                    }
                )
                
                print("🟢 Export completed successfully!")
                await MainActor.run {
                    project.isExporting = false
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: exportURL.path)
                }
            } catch {
                print("🔴 Export error: \(error)")
                print("🔴 Error description: \(error.localizedDescription)")
                await MainActor.run {
                    project.isExporting = false
                    project.exportError = error.localizedDescription
                    }
                }
            }
        }
    }


// MARK: - Checkerboard View

struct CheckerboardView: View {
    let squareSize: CGFloat = 10
    
    var body: some View {
        Canvas { context, size in
            let rows = Int(ceil(size.height / squareSize))
            let cols = Int(ceil(size.width / squareSize))
            
            for row in 0..<rows {
                for col in 0..<cols {
                    let isLight = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * squareSize,
                        y: CGFloat(row) * squareSize,
                        width: squareSize,
                        height: squareSize
                    )
                    context.fill(
                        Path(rect),
                        with: .color(isLight ? .white : Color(white: 0.9))
                    )
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
