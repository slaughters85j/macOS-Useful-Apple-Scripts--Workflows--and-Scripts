import Foundation
import CoreMedia

// MARK: - CodecNameResolver

/// Pure static FourCC-to-readable-name resolver for codecs reported by
/// `CMFormatDescriptionGetMediaSubType()`.
///
/// The legacy ffprobe pipeline produced codec names like "h264", "hevc", "aac"
/// in the `VideoMetadata.videoCodec` / `audioCodec` string fields. To keep the
/// UI's metadata rows stable after the native rewrite of `VideoProber`, we map
/// common CoreMedia FourCC values to the same lowercase identifiers ffprobe
/// emits.
///
/// Unknown FourCCs fall back to a stringified 4-character representation when
/// all bytes are printable ASCII (e.g. a new codec FourCC Apple adds later),
/// or to a `#12345678` hex literal when they are not. Either way, the UI gets
/// something to display rather than an empty string.
///
/// Shared between the native metadata prober and any other site that needs to
/// render a human-readable codec name.
enum CodecNameResolver {

    // MARK: - Public API

    /// Resolve a `CMFormatDescription` media subtype to a lowercase codec
    /// identifier matching ffprobe's `codec_name` convention where possible.
    static func name(forFourCC fourCC: UInt32) -> String {
        switch fourCC {

        // MARK: Video

        case fcc("avc1"), fcc("avc3"): return "h264"
        case fcc("hvc1"), fcc("hev1"): return "hevc"
        case fcc("av01"), fcc("AV01"): return "av1"
        case fcc("vp09"), fcc("VP90"): return "vp9"
        case fcc("vp08"), fcc("VP80"): return "vp8"
        case fcc("mp4v"):              return "mpeg4"
        case fcc("mjpg"), fcc("MJPG"), fcc("jpeg"): return "mjpeg"

        // ProRes variants. ffprobe lumps them all under "prores" with a
        // profile suffix; we match the primary codec name.
        case fcc("apcn"), fcc("apcs"), fcc("apco"),
             fcc("apch"), fcc("ap4h"), fcc("ap4x"):
            return "prores"

        // Dolby Vision is layered on top of HEVC; DVH1/DVHE carry HEVC payload.
        case fcc("dvh1"), fcc("dvhe"): return "hevc"

        case fcc("dvvd"), fcc("dvc "), fcc("dv5n"): return "dvvideo"

        // MARK: Audio

        case fcc("mp4a"):              return "aac"
        case fcc("alac"):              return "alac"
        case fcc(".mp3"), fcc("mp3 "): return "mp3"
        case fcc("ac-3"), fcc("sac3"): return "ac3"
        case fcc("ec-3"):              return "eac3"
        case fcc("opus"):              return "opus"
        case fcc("Opus"):              return "opus"

        // Linear PCM flavors (CoreAudio FourCCs). The fine-grained byte-order
        // and float/int distinction is not part of ffprobe's codec_name output,
        // so normalize to a generic "pcm".
        case kAudioFormatLinearPCM:    return "pcm"
        case fcc("lpcm"):              return "pcm"
        case fcc("sowt"), fcc("twos"): return "pcm"

        default:
            return fallbackString(for: fourCC)
        }
    } // name(forFourCC:)

    /// Render a pixel-format FourCC from a `CVPixelBuffer` or a video format
    /// description into something readable. CoreMedia pixel formats are
    /// sometimes numeric constants rather than ASCII FourCCs (e.g.
    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` = `0x34323076`), so
    /// this renders the common ones explicitly.
    static func pixelFormatName(forFourCC fourCC: UInt32) -> String {
        switch fourCC {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange: return "yuv420p"
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:  return "yuv420p(full range)"
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: return "yuv420p10le"
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:  return "yuv420p10le(full range)"
        case kCVPixelFormatType_422YpCbCr8:                   return "yuv422p"
        case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange: return "yuv422p"
        case kCVPixelFormatType_422YpCbCr10:                  return "yuv422p10le"
        case kCVPixelFormatType_444YpCbCr8:                   return "yuv444p"
        case kCVPixelFormatType_444YpCbCr10:                  return "yuv444p10le"
        case kCVPixelFormatType_32BGRA:                       return "bgra"
        case kCVPixelFormatType_32RGBA:                       return "rgba"
        default:
            return fallbackString(for: fourCC)
        }
    } // pixelFormatName(forFourCC:)

    // MARK: - Helpers

    /// Compile-time FourCC literal builder. Takes a 4-character ASCII string
    /// and returns its packed UInt32 value. Validated at function-call site
    /// via `precondition`, but `switch case` uses this only with string
    /// literals so the check is effectively compile-time.
    static func fcc(_ s: StaticString) -> UInt32 {
        precondition(s.utf8CodeUnitCount == 4, "FourCC must be 4 ASCII bytes")
        let bytes = UnsafeBufferPointer(start: s.utf8Start, count: 4)
        var result: UInt32 = 0
        for byte in bytes {
            result = (result << 8) | UInt32(byte)
        }
        return result
    } // fcc

    /// Convert a UInt32 FourCC to a 4-character ASCII string when all bytes
    /// are printable, otherwise emit a `#XXXXXXXX` hex literal. Keeps the UI
    /// from displaying empty or garbled text for codecs we don't map.
    static func fallbackString(for fourCC: UInt32) -> String {
        let bytes: [UInt8] = [
            UInt8((fourCC >> 24) & 0xff),
            UInt8((fourCC >> 16) & 0xff),
            UInt8((fourCC >> 8)  & 0xff),
            UInt8(fourCC         & 0xff)
        ]
        // Require the byte to be printable ASCII (0x20..0x7e) for the FourCC
        // rendering to be safe. Whitespace-only padding like "mp3 " is OK
        // because space (0x20) is printable.
        let allPrintable = bytes.allSatisfy { $0 >= 0x20 && $0 <= 0x7e }
        if allPrintable {
            return String(bytes: bytes, encoding: .ascii) ?? String(format: "#%08X", fourCC)
        }
        return String(format: "#%08X", fourCC)
    } // fallbackString(for:)
} // CodecNameResolver

// MARK: - Validation Tests
#if DEBUG

/// Compile-time validation harness for `CodecNameResolver`.
enum CodecNameResolverTests {

    @discardableResult
    static func runAll() -> Bool {
        var passed = 0
        var failed: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed.append(name) }
        } // check

        // MARK: Common video codecs

        check("avc1 -> h264",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("avc1")) == "h264")
        check("hvc1 -> hevc",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("hvc1")) == "hevc")
        check("hev1 -> hevc",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("hev1")) == "hevc")
        check("apcn -> prores",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("apcn")) == "prores")
        check("ap4h -> prores",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("ap4h")) == "prores")
        check("av01 -> av1",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("av01")) == "av1")

        // MARK: Common audio codecs

        check("mp4a -> aac",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("mp4a")) == "aac")
        check("alac -> alac",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("alac")) == "alac")
        check("ac-3 -> ac3",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("ac-3")) == "ac3")
        check("ec-3 -> eac3",
              CodecNameResolver.name(forFourCC: CodecNameResolver.fcc("ec-3")) == "eac3")

        // MARK: Fallback behavior for unmapped FourCCs

        let unknownAscii = CodecNameResolver.fcc("xyzw")
        check("unknown 4-char ASCII -> the 4-char string",
              CodecNameResolver.name(forFourCC: unknownAscii) == "xyzw")

        // Non-printable FourCC (use a numeric constant that isn't in our map
        // and has non-printable bytes)
        let nonPrintable: UInt32 = 0x00_01_02_03
        let result = CodecNameResolver.name(forFourCC: nonPrintable)
        check("unknown non-ASCII -> hex literal",
              result == "#00010203")

        // MARK: Pixel formats

        check("420v -> yuv420p",
              CodecNameResolver.pixelFormatName(
                forFourCC: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
              ) == "yuv420p")
        check("BGRA -> bgra",
              CodecNameResolver.pixelFormatName(
                forFourCC: kCVPixelFormatType_32BGRA
              ) == "bgra")

        print("CodecNameResolverTests: \(passed) passed, \(failed.count) failed")
        for name in failed {
            print("  FAILED: \(name)")
        }
        return failed.isEmpty
    } // runAll
} // CodecNameResolverTests

#endif
