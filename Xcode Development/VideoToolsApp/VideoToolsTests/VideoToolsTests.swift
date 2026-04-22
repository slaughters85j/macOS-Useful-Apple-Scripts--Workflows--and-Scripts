import XCTest
@testable import VideoTools

/// XCTest wrapper that drives the existing DEBUG validation harnesses baked into the app source.
/// Each test method calls a harness's runAll() and fails with a descriptive message if any
/// internal case reported a failure. No additional logic lives here.
final class VideoToolsTests: XCTestCase {

    // MARK: - Bool Harnesses

    func testGifRenderConfig() {
        XCTAssertTrue(GifRenderConfigTests.runAll(), "harness reported failures")
    }

    func testKeepSegmentCalculator() {
        XCTAssertTrue(KeepSegmentCalculatorTests.runAll(), "harness reported failures")
    }

    func testResolutionCalculator() {
        XCTAssertTrue(ResolutionCalculatorTests.runAll(), "harness reported failures")
    }

    func testColorParser() {
        XCTAssertTrue(ColorParserTests.runAll(), "harness reported failures")
    }

    func testFontResolver() {
        XCTAssertTrue(FontResolverTests.runAll(), "harness reported failures")
    }

    func testTextOverlayRenderer() {
        XCTAssertTrue(TextOverlayRendererTests.runAll(), "harness reported failures")
    }

    // MARK: - Tuple Harnesses

    func testVideoFrameExtractor() {
        let result = VideoFrameExtractorTests.runAll()
        XCTAssertEqual(result.failed, 0, "Failures: \(result.failures.joined(separator: ", "))")
    }

    func testAnimatedImageWriter() {
        let result = AnimatedImageWriterTests.runAll()
        XCTAssertEqual(result.failed, 0, "Failures: \(result.failures.joined(separator: ", "))")
    }

    func testGifRenderer() {
        let result = GifRendererTests.runAll()
        XCTAssertEqual(result.failed, 0, "Failures: \(result.failures.joined(separator: ", "))")
    }
}
