import SwiftUI
import AVFoundation

// MARK: - Timeline Constants

private enum TimelineStyle {
    static let height: CGFloat = 60
    static let thumbnailHeight: CGFloat = 50
    static let handleWidth: CGFloat = 12
    static let handleColor = Color.yellow
    static let cutStartColor = Color.green
    static let cutEndColor = Color.red
    static let playheadColor = Color.white
    static let dimmedOpacity: CGFloat = 0.4
    // Cut marker styling
    static let cutMarkerWidth: CGFloat = 2
    static let cutMarkerTabHeight: CGFloat = 16
    static let cutMarkerTabWidth: CGFloat = 10
    static let cutMarkerHitArea: CGFloat = 30
}

// MARK: - Trim Timeline View

struct TrimTimelineView: View {
    @Binding var trimStart: Double
    @Binding var trimEnd: Double?
    @Binding var cutSegments: [CutSegment]
    let duration: Double
    let videoURL: URL?
    
    @State private var thumbnails: [CGImage] = []
    @State private var isLoadingThumbnails = false
    @State private var scrubberPosition: Double = 0
    @State private var previewImage: CGImage?
    @State private var timelineWidth: CGFloat = 0
    
    private var effectiveEnd: Double {
        trimEnd ?? duration
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // Preview thumbnail
            previewThumbnail

            // Timeline with handles (extra top padding for cut marker tabs)
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    // Filmstrip background (offset down to make room for tabs)
                    filmstripBackground(width: width)
                        .offset(y: TimelineStyle.cutMarkerTabHeight / 2)

                    // Dimmed regions (outside trim range)
                    dimmedRegions(width: width)
                        .offset(y: TimelineStyle.cutMarkerTabHeight / 2)

                    // Cut segment overlays (dimmed areas)
                    cutSegmentDimmedAreas(width: width)
                        .offset(y: TimelineStyle.cutMarkerTabHeight / 2)

                    // Scrubber playhead (rendered first, so markers are on top)
                    scrubberPlayhead(width: width)
                        .offset(y: TimelineStyle.cutMarkerTabHeight / 2)

                    // Start handle (yellow)
                    trimHandle(position: trimStart, width: width, isStart: true)

                    // End handle (yellow)
                    trimHandle(position: effectiveEnd, width: width, isStart: false)

                    // Cut segment markers (green/red) - rendered on top of trim handles
                    cutSegmentMarkers(width: width)
                }
                .coordinateSpace(name: "timeline")
                .onAppear {
                    timelineWidth = width
                }
                .onChange(of: geometry.size.width) { _, newWidth in
                    timelineWidth = newWidth
                }
            }
            .frame(height: TimelineStyle.height + TimelineStyle.cutMarkerTabHeight)
            .clipped()

            // Time labels
            timeLabels

            // Cut segment controls
            cutSegmentControls
        }
        .onAppear {
            loadThumbnails()
            scrubberPosition = trimStart
        }
        .onChange(of: videoURL) { _, _ in
            loadThumbnails()
        }
    }
    
    // MARK: - Preview Thumbnail
    
    private var previewThumbnail: some View {
        Group {
            if let image = previewImage {
                Image(decorative: image, scale: 1.0)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )
                    .overlay(alignment: .bottom) {
                        Text(formatTime(scrubberPosition))
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.7))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(.bottom, 4)
                    }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 160)
                    .overlay {
                        if isLoadingThumbnails {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "film")
                                .foregroundStyle(.tertiary)
                        }
                    }
            }
        }
        .frame(maxWidth: 320)
    }
    
    // MARK: - Filmstrip Background
    
    private func filmstripBackground(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbnails.isEmpty {
                Rectangle()
                    .fill(Color.secondary.opacity(0.3))
            } else {
                ForEach(Array(thumbnails.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1.0)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width / CGFloat(max(thumbnails.count, 1)))
                        .clipped()
                }
            }
        }
        .frame(height: TimelineStyle.thumbnailHeight)
    }
    
    // MARK: - Dimmed Regions
    
    private func dimmedRegions(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            // Before trim start
            Rectangle()
                .fill(Color.black.opacity(TimelineStyle.dimmedOpacity))
                .frame(width: positionToX(trimStart, width: width))
            
            // After trim end
            Rectangle()
                .fill(Color.black.opacity(TimelineStyle.dimmedOpacity))
                .frame(width: width - positionToX(effectiveEnd, width: width))
                .offset(x: positionToX(effectiveEnd, width: width))
        }
        .frame(height: TimelineStyle.thumbnailHeight)
    }
    
    // MARK: - Cut Segment Dimmed Areas

    private func cutSegmentDimmedAreas(width: CGFloat) -> some View {
        ForEach(cutSegments) { segment in
            let startX = positionToX(segment.startTime, width: width)
            let endX = positionToX(segment.endTime, width: width)
            let segmentWidth = max(0, endX - startX)

            Rectangle()
                .fill(Color.red.opacity(0.3))
                .frame(width: segmentWidth, height: TimelineStyle.thumbnailHeight)
                .position(x: startX + segmentWidth / 2, y: TimelineStyle.height / 2)
        }
    }

    // MARK: - Cut Segment Markers

    private func cutSegmentMarkers(width: CGFloat) -> some View {
        ForEach(cutSegments) { segment in
            // Start marker (green)
            cutMarker(
                segment: segment,
                isStart: true,
                width: width
            )

            // End marker (red)
            cutMarker(
                segment: segment,
                isStart: false,
                width: width
            )
        }
    }

    private func cutMarker(segment: CutSegment, isStart: Bool, width: CGFloat) -> some View {
        let time = isStart ? segment.startTime : segment.endTime
        let xPos = positionToX(time, width: width)
        let color = isStart ? TimelineStyle.cutStartColor : TimelineStyle.cutEndColor
        let totalHeight = TimelineStyle.height + TimelineStyle.cutMarkerTabHeight

        return ZStack {
            // Invisible wider hit area
            Rectangle()
                .fill(Color.clear)
                .frame(width: TimelineStyle.cutMarkerHitArea, height: totalHeight)

            // Visible marker
            CutMarkerShape(isStart: isStart)
                .fill(color)
                .frame(width: TimelineStyle.cutMarkerTabWidth, height: totalHeight)
                .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
        }
        .position(x: xPos, y: totalHeight / 2)
        .gesture(
            DragGesture(coordinateSpace: .named("timeline"))
                .onChanged { value in
                    let newTime = xToPosition(value.location.x, width: width)
                    updateCutMarker(segment: segment, isStart: isStart, newTime: newTime)
                    scrubberPosition = max(trimStart, min(newTime, effectiveEnd))
                    updatePreviewFrame()
                }
        )
    }

    private func updateCutMarker(segment: CutSegment, isStart: Bool, newTime: Double) {
        guard let index = cutSegments.firstIndex(where: { $0.id == segment.id }) else { return }

        var updatedSegment = cutSegments[index]

        if isStart {
            // Start marker: clamp between trimStart and current endTime - 0.1
            let clampedTime = max(trimStart, min(newTime, updatedSegment.endTime - 0.1))
            updatedSegment = CutSegment(id: segment.id, startTime: clampedTime, endTime: updatedSegment.endTime)
        } else {
            // End marker: clamp between current startTime + 0.1 and effectiveEnd
            let clampedTime = max(updatedSegment.startTime + 0.1, min(newTime, effectiveEnd))
            updatedSegment = CutSegment(id: segment.id, startTime: updatedSegment.startTime, endTime: clampedTime)
        }

        cutSegments[index] = updatedSegment
    }
    
    // MARK: - Trim Handle

    private func trimHandle(position: Double, width: CGFloat, isStart: Bool) -> some View {
        let xPos = positionToX(position, width: width)
        let totalHeight = TimelineStyle.height + TimelineStyle.cutMarkerTabHeight

        return ZStack {
            // Invisible wider hit area
            Rectangle()
                .fill(Color.clear)
                .frame(width: TimelineStyle.cutMarkerHitArea, height: totalHeight)

            // Visible marker
            TrimMarkerShape()
                .fill(TimelineStyle.handleColor)
                .frame(width: TimelineStyle.cutMarkerTabWidth, height: totalHeight)
                .shadow(color: .black.opacity(0.4), radius: 1, x: 0, y: 1)
        }
        .position(x: xPos, y: totalHeight / 2)
        .gesture(
            DragGesture(coordinateSpace: .named("timeline"))
                .onChanged { value in
                    let newTime = xToPosition(value.location.x, width: width)
                    if isStart {
                        trimStart = max(0, min(newTime, effectiveEnd - 0.1))
                        scrubberPosition = trimStart
                    } else {
                        let clampedTime = max(trimStart + 0.1, min(newTime, duration))
                        trimEnd = clampedTime
                        scrubberPosition = clampedTime
                    }
                    updatePreviewFrame()
                }
        )
    }
    
    // MARK: - Scrubber Playhead
    // The scrubber follows the active marker - no independent dragging

    private func scrubberPlayhead(width: CGFloat) -> some View {
        let xPos = positionToX(scrubberPosition, width: width)

        return Rectangle()
            .fill(TimelineStyle.playheadColor.opacity(0.7))
            .frame(width: 2, height: TimelineStyle.height)
            .shadow(color: .black.opacity(0.3), radius: 1)
            .position(x: xPos, y: TimelineStyle.height / 2)
            .allowsHitTesting(false) // Scrubber doesn't intercept touches
    }
    
    // MARK: - Time Labels
    
    private var timeLabels: some View {
        HStack {
            Text(formatTime(trimStart))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            
            Spacer()
            
            if !cutSegments.isEmpty {
                Text("Final: \(formatTime(calculatedDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.green)
            }
            
            Spacer()
            
            Text(formatTime(effectiveEnd))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Cut Segment Controls

    private var cutSegmentControls: some View {
        HStack {
            Button {
                addCutSegment()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle.fill")
                    Text("Add Cut")
                    // Color indicators
                    Circle().fill(TimelineStyle.cutStartColor).frame(width: 8, height: 8)
                    Circle().fill(TimelineStyle.cutEndColor).frame(width: 8, height: 8)
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            
            Spacer()
            
            if !cutSegments.isEmpty {
                Button {
                    removeLastCutSegment()
                } label: {
                    Label("Remove Last", systemImage: "minus.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func positionToX(_ time: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * width
    }
    
    private func xToPosition(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(x / width) * duration
    }
    
    private var calculatedDuration: Double {
        let baseDuration = effectiveEnd - trimStart
        let cutTotal = cutSegments.reduce(0) { $0 + $1.duration }
        return max(0, baseDuration - cutTotal)
    }
    
    private func formatTime(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let fraction = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%d:%02d.%02d", mins, secs, fraction)
    }
    
    private func addCutSegment() {
        // Add a new cut in the middle of the trim range
        let trimRange = effectiveEnd - trimStart
        let centerTime = trimStart + trimRange / 2

        // Create a segment that's ~10% of the trim range, minimum 0.5s separation
        let halfWidth = max(0.5, trimRange * 0.05)
        let segmentStart = max(trimStart + 0.1, centerTime - halfWidth)
        let segmentEnd = min(effectiveEnd - 0.1, centerTime + halfWidth)

        guard segmentEnd > segmentStart else { return }

        let newSegment = CutSegment(startTime: segmentStart, endTime: segmentEnd)
        cutSegments.append(newSegment)

        // Move scrubber to the new segment
        scrubberPosition = centerTime
        updatePreviewFrame()
    }
    
    private func removeLastCutSegment() {
        guard !cutSegments.isEmpty else { return }
        cutSegments.removeLast()
    }
    
    // MARK: - Thumbnail Generation
    
    private func loadThumbnails() {
        guard let url = videoURL else { return }
        isLoadingThumbnails = true
        
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 120, height: 80)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            
            let durationValue = try? await asset.load(.duration).seconds
            guard let videoDuration = durationValue, videoDuration > 0 else {
                isLoadingThumbnails = false
                return
            }
            
            // Generate ~10 thumbnails for the filmstrip
            let count = 10
            var images: [CGImage] = []
            
            for i in 0..<count {
                let time = CMTime(seconds: videoDuration * Double(i) / Double(count), preferredTimescale: 600)
                if let (cgImage, _) = try? await generator.image(at: time) {
                    images.append(cgImage)
                }
            }
            
            // Also generate initial preview
            let previewTime = CMTime(seconds: 0, preferredTimescale: 600)
            let preview = try? await generator.image(at: previewTime).image
            
            thumbnails = images
            previewImage = preview
            isLoadingThumbnails = false
        }
    }
    
    private func updatePreviewFrame() {
        guard let url = videoURL else { return }
        
        // Capture scrubber position before entering task
        let currentPosition = scrubberPosition
        
        Task {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 240)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
            
            let time = CMTime(seconds: currentPosition, preferredTimescale: 600)
            if let (cgImage, _) = try? await generator.image(at: time) {
                previewImage = cgImage
            }
        }
    }
}

// MARK: - Trim Marker Shape (Yellow tab + line style)

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

#Preview {
    TrimTimelineView(
        trimStart: .constant(2.0),
        trimEnd: .constant(28.0),
        cutSegments: .constant([
            CutSegment(startTime: 10, endTime: 15)
        ]),
        duration: 30.0,
        videoURL: nil
    )
    .frame(width: 400)
    .padding()
}
