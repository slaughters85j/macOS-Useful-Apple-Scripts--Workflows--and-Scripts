#!/usr/bin/env python3
"""
Video to GIF Converter - Batch processor for creating animated GIFs from video files.
Designed to be called from a SwiftUI app with JSON configuration.

Features:
- Multi-segment trimming (remove arbitrary sections from the middle)
- Resolution control (scale, fixed width, custom dimensions)
- Frame rate and speed adjustment
- Output format selection: GIF (palette-optimized), APNG (full 24-bit lossless), or WebP (lossy, best size/quality)
- Optimal palette generation for high-quality GIFs (skipped for APNG)
- Configurable dithering and color count (GIF only)
- Loop control (infinite, once, or custom count)

Usage:
    echo '{"files": [...], "config": {...}}' | python video_to_gif.py
    python video_to_gif.py --config config.json

Input JSON Schema:
{
    "files": ["/path/to/video1.mp4", "/path/to/video2.mov"],
    "config": {
        "resolution": {
            "mode": "original" | "scale" | "width" | "custom",
            "scalePercent": 50,
            "width": 480,
            "height": 360
        },
        "frame_rate": 15,
        "speed_multiplier": 1.0,
        "loop_count": 0,  // 0 = infinite, 1 = once, N = N times
        "dither_method": "floyd_steinberg" | "bayer" | "sierra2_4a" | "none",
        "color_count": 256,
        "output_format": "gif" | "apng" | "webp",  // default: "gif"
        "webp_quality": 80,  // 1-100, WebP only
        "trim_start": 0,
        "trim_end": null,  // null = use video duration
        "cut_segments": [  // segments to REMOVE
            {"start": 5.0, "end": 8.0},
            {"start": 15.0, "end": 17.0}
        ],
        "text_overlay": {  // optional styled text overlay
            "text": "Hello World",
            "start": 1.0, "end": 5.0,
            "x": 0.5, "y": 0.5,
            "font_size": 48, "font_name": "Helvetica",
            "bold": false, "italic": false,
            "color": "0xFFFFFF@1.0",
            "shadow": true, "shadow_color": "0x000000@1.0",
            "shadow_x": 2, "shadow_y": 2,
            "gradient_enabled": false,
            "gradient_start_color": "#FFFFFF",
            "gradient_end_color": "#0099FF",
            "gradient_angle": 0
        }
    }
}

Output: JSON lines (one per event) to stdout
"""

import os
import sys
import json
import subprocess
import tempfile
import shutil
from pathlib import Path
from enum import Enum
from typing import Optional, List, Tuple

sys.stdout.reconfigure(line_buffering=True)


# MARK: - Font mapping (curated list of macOS system fonts)
FONT_MAP = {
    "Helvetica": "/System/Library/Fonts/Helvetica.ttc",
    "Arial": "/System/Library/Fonts/Supplemental/Arial.ttf",
    "Courier": "/System/Library/Fonts/Courier.dfont",
    "Courier New": "/System/Library/Fonts/Supplemental/Courier New.ttf",
    "Georgia": "/System/Library/Fonts/Supplemental/Georgia.ttf",
    "Times New Roman": "/System/Library/Fonts/Supplemental/Times New Roman.ttf",
    "Menlo": "/System/Library/Fonts/Menlo.ttc",
    "SF Pro": "/System/Library/Fonts/SFNS.ttf",
    "Avenir": "/System/Library/Fonts/Avenir.ttc",
    "Futura": "/System/Library/Fonts/Supplemental/Futura.ttc",
    "Didot": "/System/Library/Fonts/Supplemental/Didot.ttc",
    "Palatino": "/System/Library/Fonts/Supplemental/Palatino.ttc",
    "Optima": "/System/Library/Fonts/Supplemental/Optima.ttc",
    "Trebuchet MS": "/System/Library/Fonts/Supplemental/Trebuchet MS.ttf",
    "Verdana": "/System/Library/Fonts/Supplemental/Verdana.ttf",
    "Impact": "/System/Library/Fonts/Supplemental/Impact.ttf",
}

# Bold/Italic font file variants for common fonts
FONT_STYLE_MAP = {
    "Arial": {
        (True, False): "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Arial Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Arial Bold Italic.ttf",
    },
    "Courier New": {
        (True, False): "/System/Library/Fonts/Supplemental/Courier New Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Courier New Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Courier New Bold Italic.ttf",
    },
    "Georgia": {
        (True, False): "/System/Library/Fonts/Supplemental/Georgia Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Georgia Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Georgia Bold Italic.ttf",
    },
    "Times New Roman": {
        (True, False): "/System/Library/Fonts/Supplemental/Times New Roman Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Times New Roman Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Times New Roman Bold Italic.ttf",
    },
    "Trebuchet MS": {
        (True, False): "/System/Library/Fonts/Supplemental/Trebuchet MS Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Trebuchet MS Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Trebuchet MS Bold Italic.ttf",
    },
    "Verdana": {
        (True, False): "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
        (False, True): "/System/Library/Fonts/Supplemental/Verdana Italic.ttf",
        (True, True): "/System/Library/Fonts/Supplemental/Verdana Bold Italic.ttf",
    },
}


def find_font_file(font_name: str, bold: bool = False, italic: bool = False) -> str:
    """Resolve a font display name + style to a file path on macOS."""
    # Check for style-specific variant first
    style_key = (bold, italic)
    if style_key != (False, False) and font_name in FONT_STYLE_MAP:
        variant = FONT_STYLE_MAP[font_name].get(style_key)
        if variant and os.path.isfile(variant):
            return variant

    # Fall back to base font
    base = FONT_MAP.get(font_name)
    if base and os.path.isfile(base):
        return base

    # Last resort: Helvetica
    fallback = "/System/Library/Fonts/Helvetica.ttc"
    return fallback if os.path.isfile(fallback) else "Helvetica"


def adjust_overlay_time(
    overlay: dict,
    keep_segments: List[Tuple[float, float]]
) -> Optional[Tuple[float, float]]:
    """
    Map text overlay start/end times from the original video timeline
    to the output timeline (after trims and cuts are applied).

    Returns (adjusted_start, adjusted_end) in output timeline coordinates,
    or None if the overlay falls entirely outside kept segments.
    """
    overlay_start = overlay['start']
    overlay_end = overlay['end']

    # Accumulate output time as we walk through kept segments
    output_time = 0.0
    adjusted_start = None
    adjusted_end = None

    for seg_start, seg_end in keep_segments:
        seg_duration = seg_end - seg_start

        # Find where the overlay intersects this segment
        visible_start = max(overlay_start, seg_start)
        visible_end = min(overlay_end, seg_end)

        if visible_start < visible_end:
            # Overlay is visible during this segment
            offset_in_seg = visible_start - seg_start
            if adjusted_start is None:
                adjusted_start = output_time + offset_in_seg
            adjusted_end = output_time + (visible_end - seg_start)

        output_time += seg_duration

    if adjusted_start is not None and adjusted_end is not None:
        return (adjusted_start, adjusted_end)
    return None


def build_drawtext_filter(
    overlay: dict,
    video_width: int,
    video_height: int,
    adjusted_start: float,
    adjusted_end: float,
    scale_filter: str
) -> str:
    """
    Build an FFmpeg drawtext filter string for a single text overlay.
    Handles font resolution, position, color, and shadow.
    """
    text = overlay['text'].replace("'", "'\\\\\\''").replace(":", "\\:")
    font_path = find_font_file(
        overlay['font_name'],
        overlay.get('bold', False),
        overlay.get('italic', False)
    )

    # Calculate output dimensions from scale filter
    out_w, out_h = _parse_output_dimensions(scale_filter, video_width, video_height)

    # Position: normalized (0-1) → pixel coords, centered on the text
    # SwiftUI .position() places the view's CENTER at the coordinate,
    # so we must subtract half text dimensions to match.
    cx = int(overlay['x'] * out_w)
    cy = int(overlay['y'] * out_h)

    parts = [
        f"drawtext=text='{text}'",
        f"fontfile='{font_path}'",
        f"fontsize={overlay['font_size']}",
        f"fontcolor={overlay['color']}",
        f"x={cx}-text_w/2",
        f"y={cy}-text_h/2",
        f"enable='between(t\\,{adjusted_start:.3f}\\,{adjusted_end:.3f})'",
    ]

    if overlay.get('shadow', False):
        parts.append(f"shadowcolor={overlay['shadow_color']}")
        parts.append(f"shadowx={overlay['shadow_x']}")
        parts.append(f"shadowy={overlay['shadow_y']}")

    return ":".join(parts)


def _parse_output_dimensions(scale_filter: str, src_w: int, src_h: int) -> Tuple[int, int]:
    """Parse output dimensions from a scale filter string like 'scale=640:480'."""
    try:
        parts = scale_filter.replace("scale=", "").split(":")
        w = int(parts[0])
        h_str = parts[1]
        if h_str == "-2":
            # Maintain aspect ratio, round to even
            h = int(round(src_h * (w / src_w) / 2) * 2)
        elif h_str == "-1":
            h = int(round(src_h * (w / src_w)))
        else:
            h = int(h_str)
        return (w, h)
    except (ValueError, IndexError):
        return (src_w, src_h)


def render_gradient_text_png(
    overlay: dict,
    video_width: int,
    video_height: int,
    output_path: str,
    scale_filter: str
) -> bool:
    """
    Render text with a gradient fill as a transparent PNG using Pillow.
    Returns True on success, False if Pillow is not available.
    """
    try:
        from PIL import Image, ImageDraw, ImageFont
    except ImportError:
        return False

    out_w, out_h = _parse_output_dimensions(scale_filter, video_width, video_height)

    # Load font
    font_path = find_font_file(
        overlay['font_name'],
        overlay.get('bold', False),
        overlay.get('italic', False)
    )
    try:
        font = ImageFont.truetype(font_path, overlay['font_size'])
    except Exception:
        font = ImageFont.load_default()

    # Create transparent canvas
    canvas = Image.new('RGBA', (out_w, out_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)

    # Get text bounding box
    text = overlay['text']
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]

    if text_w <= 0 or text_h <= 0:
        return False

    # Render white text on transparent background (as mask)
    text_img = Image.new('RGBA', (text_w, text_h), (0, 0, 0, 0))
    text_draw = ImageDraw.Draw(text_img)
    text_draw.text((-bbox[0], -bbox[1]), text, fill=(255, 255, 255, 255), font=font)

    # Create gradient
    angle_rad = overlay.get('gradient_angle', 0) * 3.14159265 / 180.0

    # Parse hex colors (#RRGGBB)
    start_hex = overlay.get('gradient_start_color', '#FFFFFF')
    end_hex = overlay.get('gradient_end_color', '#0099FF')
    start_rgb = _hex_to_rgb(start_hex)
    end_rgb = _hex_to_rgb(end_hex)

    gradient = _create_gradient_image(text_w, text_h, start_rgb, end_rgb, angle_rad)

    # Apply: use text alpha as mask over gradient color
    result = Image.new('RGBA', (text_w, text_h), (0, 0, 0, 0))
    for py in range(text_h):
        for px in range(text_w):
            gr, gg, gb, _ = gradient.getpixel((px, py))
            _, _, _, ta = text_img.getpixel((px, py))
            result.putpixel((px, py), (gr, gg, gb, ta))

    # Center text at the normalized position (matching SwiftUI .position() behavior)
    text_x = int(overlay['x'] * out_w) - text_w // 2
    text_y = int(overlay['y'] * out_h) - text_h // 2

    # Shadow (render behind text)
    if overlay.get('shadow', False):
        shadow_color = _hex_to_rgb(overlay.get('shadow_color', '0x000000@1.0').replace('0x', '#').split('@')[0])
        sx = overlay.get('shadow_x', 2)
        sy = overlay.get('shadow_y', 2)

        shadow_img = Image.new('RGBA', (text_w, text_h), (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow_img)
        shadow_draw.text((-bbox[0], -bbox[1]), text, fill=(*shadow_color, 180), font=font)

        canvas.paste(shadow_img, (text_x + sx, text_y + sy), shadow_img)

    # Position text on canvas (centered)
    canvas.paste(result, (text_x, text_y), result)

    canvas.save(output_path, 'PNG')
    return True


def _hex_to_rgb(hex_str: str) -> Tuple[int, int, int]:
    """Convert '#RRGGBB' or '0xRRGGBB' to (R, G, B) tuple."""
    hex_str = hex_str.lstrip('#').replace('0x', '')
    if len(hex_str) >= 6:
        return (int(hex_str[0:2], 16), int(hex_str[2:4], 16), int(hex_str[4:6], 16))
    return (255, 255, 255)


def _create_gradient_image(
    width: int, height: int,
    start_rgb: Tuple[int, int, int],
    end_rgb: Tuple[int, int, int],
    angle_rad: float
) -> 'Image':
    """Create a gradient image using linear interpolation along an angle."""
    from PIL import Image
    import math

    img = Image.new('RGBA', (width, height))
    cos_a = math.cos(angle_rad)
    sin_a = math.sin(angle_rad)

    # Project corners to find the range along the gradient axis
    max_proj = abs(cos_a * width) + abs(sin_a * height)
    if max_proj == 0:
        max_proj = 1

    for py in range(height):
        for px in range(width):
            # Project point onto gradient axis
            proj = (px * cos_a + py * sin_a + max_proj / 2) / max_proj
            proj = max(0.0, min(1.0, proj))

            r = int(start_rgb[0] + (end_rgb[0] - start_rgb[0]) * proj)
            g = int(start_rgb[1] + (end_rgb[1] - start_rgb[1]) * proj)
            b = int(start_rgb[2] + (end_rgb[2] - start_rgb[2]) * proj)
            img.putpixel((px, py), (r, g, b, 255))

    return img


class EventType(Enum):
    START = "start"
    PROGRESS = "progress"
    FILE_START = "file_start"
    FILE_COMPLETE = "file_complete"
    FILE_ERROR = "file_error"
    COMPLETE = "complete"
    ERROR = "error"


def emit_event(event_type: EventType, **kwargs):
    """Emit a JSON event to stdout for the Swift app to consume."""
    event = {"event": event_type.value, **kwargs}
    print(json.dumps(event), flush=True)


def check_webp_support(ffmpeg_path: str) -> bool:
    """Check if this FFmpeg binary has libwebp compiled in."""
    try:
        result = subprocess.run(
            [ffmpeg_path, '-encoders'],
            capture_output=True, text=True
        )
        return 'webp' in result.stdout.lower()
    except Exception:
        return False


def create_webp_with_pillow(
    source_path: str,
    vf_filters: List[str],
    loop_count: int,
    webp_quality: int,
    frame_rate: float,
    output_path: str,
    ffmpeg_path: str,
    temp_dir: str
) -> None:
    """
    Create animated WebP via Pillow — fallback when FFmpeg lacks libwebp.
    Extracts frames as PNGs with FFmpeg, then assembles them with Pillow.
    """
    try:
        from PIL import Image
    except ImportError:
        raise Exception(
            "WebP output requires either FFmpeg with libwebp support or Pillow. "
            "Install Pillow via: pip install Pillow  "
            "Or get a full FFmpeg via: conda install -c conda-forge ffmpeg"
        )

    frames_dir = os.path.join(temp_dir, "webp_frames")
    os.makedirs(frames_dir, exist_ok=True)

    # Extract frames as JPEG (much faster than PNG — we're going lossy anyway)
    frame_pattern = os.path.join(frames_dir, "frame_%06d.jpg")
    cmd = [
        ffmpeg_path, '-y',
        '-i', source_path,
        '-vf', ",".join(vf_filters),
        '-q:v', '2',  # JPEG quality 1-31, lower = better (2 ≈ 95% quality)
        frame_pattern
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        raise Exception(f"Frame extraction failed: {result.stderr[:200]}")

    # Load frames in order
    frame_files = sorted(
        os.path.join(frames_dir, f)
        for f in os.listdir(frames_dir)
        if f.endswith('.jpg')
    )
    if not frame_files:
        raise Exception("No frames extracted from video")

    # Use RGB — video content has no alpha, avoids unnecessary conversion overhead
    frames = [Image.open(f).convert('RGB') for f in frame_files]
    frame_duration_ms = max(1, int(1000 / frame_rate))

    # Pass duration as a list — single integer is unreliable in Pillow for WebP
    # and causes subsequent frames to fall back to a slow default (~1000ms each)
    durations = [frame_duration_ms] * len(frames)

    # Save animated WebP — loop=0 means infinite (matches GIF/APNG convention)
    # method=2: good balance of encode speed vs compression ratio (0=fastest, 6=best)
    frames[0].save(
        output_path,
        format='WEBP',
        save_all=True,
        append_images=frames[1:],
        loop=loop_count,
        duration=durations,
        quality=webp_quality,
        method=2
    )


def get_ffmpeg_path() -> str:
    """Get the ffmpeg binary path."""
    home = os.path.expanduser("~")
    common_paths = [
        # User conda environments (often have full ffmpeg with libx264)
        os.path.join(home, "miniforge3/bin/ffmpeg"),
        os.path.join(home, "miniconda3/bin/ffmpeg"),
        os.path.join(home, "anaconda3/bin/ffmpeg"),
        # Homebrew
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        # System
        "/usr/bin/ffmpeg"
    ]
    for path in common_paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return "ffmpeg"


def probe_video(video_path: str, ffmpeg_path: str) -> Optional[dict]:
    """Get video metadata using ffprobe."""
    ffprobe_path = ffmpeg_path.replace("ffmpeg", "ffprobe")
    try:
        cmd = [
            ffprobe_path, "-v", "quiet", "-print_format", "json",
            "-show_format", "-show_streams", video_path
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        probe = json.loads(result.stdout)
        
        video_stream = next(
            (s for s in probe['streams'] if s['codec_type'] == 'video'), None
        )
        if not video_stream:
            return None
        
        return {
            'width': int(video_stream['width']),
            'height': int(video_stream['height']),
            'duration': float(probe['format']['duration'])
        }
    except Exception as e:
        emit_event(EventType.ERROR, message=f"Failed to probe {video_path}: {e}")
        return None


def snap_to_frame(time: float, fps: float) -> float:
    """Snap a time value to the nearest frame boundary for the given fps."""
    if fps <= 0:
        return time
    frame_duration = 1.0 / fps
    frame_num = round(time / frame_duration)
    return frame_num * frame_duration


def calculate_keep_segments(
    duration: float,
    trim_start: float,
    trim_end: Optional[float],
    cut_segments: List[dict],
    target_fps: float = 0
) -> List[Tuple[float, float]]:
    """
    Calculate the segments to KEEP after applying trims and cuts.

    Args:
        duration: Total video duration
        trim_start: Start time to begin from
        trim_end: End time to stop at (None = use duration)
        cut_segments: List of {"start": float, "end": float} to remove
        target_fps: If > 0, snap times to frame boundaries

    Returns:
        List of (start, end) tuples representing segments to keep
    """
    effective_end = trim_end if trim_end is not None else duration

    # Snap to frame boundaries if fps specified
    if target_fps > 0:
        trim_start = snap_to_frame(trim_start, target_fps)
        effective_end = snap_to_frame(effective_end, target_fps)

    # Start with the full trimmed range
    keep_ranges = [(trim_start, effective_end)]

    # Sort cut segments by start time
    cuts = sorted(cut_segments, key=lambda x: x['start'])

    # Apply each cut (with optional frame snapping)
    for cut in cuts:
        cut_start = cut['start']
        cut_end = cut['end']

        if target_fps > 0:
            cut_start = snap_to_frame(cut_start, target_fps)
            cut_end = snap_to_frame(cut_end, target_fps)

        new_ranges = []
        for (start, end) in keep_ranges:
            # Cut is completely outside this range
            if cut_end <= start or cut_start >= end:
                new_ranges.append((start, end))
            # Cut overlaps the start
            elif cut_start <= start and cut_end < end:
                new_ranges.append((cut_end, end))
            # Cut overlaps the end
            elif cut_start > start and cut_end >= end:
                new_ranges.append((start, cut_start))
            # Cut is in the middle - split the range
            elif cut_start > start and cut_end < end:
                new_ranges.append((start, cut_start))
                new_ranges.append((cut_end, end))
            # Cut completely covers this range - skip it

        keep_ranges = new_ranges

    return keep_ranges


def build_scale_filter(resolution_config: dict, source_width: int, source_height: int) -> str:
    """Build the FFmpeg scale filter string."""
    mode = resolution_config.get('mode', 'original')
    
    if mode == 'original':
        return f"scale={source_width}:{source_height}"
    elif mode == 'scale':
        percent = resolution_config.get('scalePercent', 50) / 100.0
        w = int(source_width * percent)
        h = int(source_height * percent)
        # Ensure even dimensions for compatibility
        w = w if w % 2 == 0 else w + 1
        h = h if h % 2 == 0 else h + 1
        return f"scale={w}:{h}"
    elif mode == 'width':
        target_width = resolution_config.get('width', 480)
        # -1 maintains aspect ratio, but we need to ensure even height
        return f"scale={target_width}:-2"
    elif mode == 'custom':
        w = resolution_config.get('width', 640)
        h = resolution_config.get('height', 480)
        return f"scale={w}:{h}"
    
    return f"scale={source_width}:{source_height}"


def process_video_to_gif(
    video_path: str,
    config: dict,
    ffmpeg_path: str
) -> dict:
    """Convert a single video file to GIF."""
    file_id = Path(video_path).name
    emit_event(EventType.FILE_START, file=file_id, path=video_path)
    
    # Probe video
    info = probe_video(video_path, ffmpeg_path)
    if not info:
        emit_event(EventType.FILE_ERROR, file=file_id, error="Failed to probe video")
        return {"success": False, "file": file_id, "error": "Failed to probe video"}
    
    # Extract config
    resolution_config = config.get('resolution', {'mode': 'original'})
    frame_rate = config.get('frame_rate', 15)
    speed_mult = config.get('speed_multiplier', 1.0)
    loop_count = config.get('loop_count', 0)
    dither_method = config.get('dither_method', 'floyd_steinberg')
    color_count = config.get('color_count', 256)
    output_format = config.get('output_format', 'gif')  # 'gif', 'apng', or 'webp'
    is_apng = output_format == 'apng'
    is_webp = output_format == 'webp'
    webp_quality = config.get('webp_quality', 80)
    trim_start = config.get('trim_start', 0)
    trim_end = config.get('trim_end')
    cut_segments = config.get('cut_segments', [])
    text_overlay = config.get('text_overlay')  # Optional text overlay config
    
    # Calculate segments to keep (snap to target frame rate for precision)
    keep_segments = calculate_keep_segments(
        info['duration'], trim_start, trim_end, cut_segments, target_fps=frame_rate
    )
    
    if not keep_segments:
        emit_event(EventType.FILE_ERROR, file=file_id, error="No video content remaining after cuts")
        return {"success": False, "file": file_id, "error": "No video content remaining after cuts"}
    
    # Build output path
    input_dir = os.path.dirname(os.path.abspath(video_path)) or '.'
    input_name = Path(video_path).stem
    if is_apng:
        output_ext = ".png"
    elif is_webp:
        output_ext = ".webp"
    else:
        output_ext = ".gif"
    output_path = os.path.join(input_dir, f"{input_name}{output_ext}")
    
    # Build scale filter
    scale_filter = build_scale_filter(resolution_config, info['width'], info['height'])
    
    # Speed filter (setpts for video speed)
    speed_filter = f"setpts={1.0/speed_mult}*PTS" if speed_mult != 1.0 else ""
    
    # Pre-compute text overlay timing adjustment
    adjusted_text_times = None
    if text_overlay and text_overlay.get('text', '').strip():
        adjusted_text_times = adjust_overlay_time(text_overlay, keep_segments)
        if adjusted_text_times is None:
            emit_event(EventType.PROGRESS, message="Text overlay falls outside kept segments, skipping")
            text_overlay = None

    try:
        with tempfile.TemporaryDirectory() as temp_dir:
            # If we have multiple segments, we need to extract and concat them
            if len(keep_segments) > 1:
                segment_files = []

                for i, (start, end) in enumerate(keep_segments):
                    segment_path = os.path.join(temp_dir, f"segment_{i:03d}.mp4")
                    seg_duration = end - start

                    # Use -ss AFTER -i for frame-accurate seeking (output seeking)
                    # Re-encode for precise cuts (not stream copy)
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', video_path,
                        '-ss', f'{start:.6f}',      # After -i = frame-accurate
                        '-t', f'{seg_duration:.6f}',
                        '-c:v', 'libx264',          # Re-encode for precision
                        '-preset', 'fast',
                        '-crf', '18',               # High quality intermediate
                        '-c:a', 'aac',
                        '-avoid_negative_ts', 'make_zero',
                        segment_path
                    ]

                    result = subprocess.run(cmd, capture_output=True, text=True)
                    if result.returncode != 0:
                        raise Exception(f"Segment extraction failed: {result.stderr[:200]}")

                    segment_files.append(segment_path)
                
                # Create concat file
                concat_path = os.path.join(temp_dir, "concat.txt")
                with open(concat_path, 'w') as f:
                    for seg in segment_files:
                        f.write(f"file '{seg}'\n")
                
                # Concat segments
                merged_path = os.path.join(temp_dir, "merged.mp4")
                cmd = [
                    ffmpeg_path, '-y',
                    '-f', 'concat', '-safe', '0',
                    '-i', concat_path,
                    '-c', 'copy',
                    merged_path
                ]
                
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    raise Exception(f"Concat failed: {result.stderr[:200]}")
                
                source_for_gif = merged_path
                input_opts = []
            else:
                # Single segment - build trim filter for frame-accurate cuts
                source_for_gif = video_path
                start, end = keep_segments[0]
                seg_duration = end - start
                # Use trim filter for frame-accurate cutting with filter_complex
                trim_filter = f"trim=start={start:.6f}:duration={seg_duration:.6f},setpts=PTS-STARTPTS"

            # Build the text drawtext filter if applicable (non-gradient)
            drawtext_filter = None
            gradient_png_path = None
            if text_overlay and adjusted_text_times and not text_overlay.get('gradient_enabled', False):
                drawtext_filter = build_drawtext_filter(
                    text_overlay, info['width'], info['height'],
                    adjusted_text_times[0], adjusted_text_times[1],
                    scale_filter
                )
            elif text_overlay and adjusted_text_times and text_overlay.get('gradient_enabled', False):
                gradient_png_path = os.path.join(temp_dir, "text_overlay.png")
                try:
                    success = render_gradient_text_png(
                        text_overlay, info['width'], info['height'],
                        gradient_png_path, scale_filter
                    )
                except Exception as e:
                    emit_event(EventType.PROGRESS,
                               message=f"Gradient rendering error: {e}, using solid color")
                    success = False

                if not success:
                    emit_event(EventType.PROGRESS,
                               message="Gradient rendering failed (Pillow missing?), using solid color")
                    gradient_png_path = None
                    text_overlay['gradient_enabled'] = False
                    drawtext_filter = build_drawtext_filter(
                        text_overlay, info['width'], info['height'],
                        adjusted_text_times[0], adjusted_text_times[1],
                        scale_filter
                    )
                else:
                    # Verify the PNG was actually created
                    if not os.path.isfile(gradient_png_path) or os.path.getsize(gradient_png_path) == 0:
                        emit_event(EventType.PROGRESS,
                                   message="Gradient PNG is empty/missing, using solid color")
                        gradient_png_path = None
                        text_overlay['gradient_enabled'] = False
                        drawtext_filter = build_drawtext_filter(
                            text_overlay, info['width'], info['height'],
                            adjusted_text_times[0], adjusted_text_times[1],
                            scale_filter
                        )
                    else:
                        emit_event(EventType.PROGRESS,
                                   message=f"Gradient text PNG rendered ({os.path.getsize(gradient_png_path)} bytes)")

            if is_webp:
                # --- WebP path: lossy, full color, best size/quality tradeoff ---
                # Build filter list (shared by both FFmpeg and Pillow paths)
                if len(keep_segments) > 1:
                    # Multi-segment: source is already trimmed/merged
                    vf_filters = [f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        vf_filters.insert(0, speed_filter)
                else:
                    # Single segment: apply trim filter first
                    vf_filters = [trim_filter, f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        vf_filters.insert(1, speed_filter)

                # Add drawtext after scale (non-gradient text)
                if drawtext_filter:
                    vf_filters.append(drawtext_filter)

                if check_webp_support(ffmpeg_path):
                    # FFmpeg has libwebp — direct encode
                    if gradient_png_path:
                        # Gradient text: use filter_complex with overlay
                        vf_str = ",".join(vf_filters)
                        fc = (f"[0:v]{vf_str}[v];"
                              f"[v][1:v]overlay=0:0:"
                              f"enable='between(t\\,{adjusted_text_times[0]:.3f}\\,{adjusted_text_times[1]:.3f})'")
                        cmd = [
                            ffmpeg_path, '-y',
                            '-i', source_for_gif,
                            '-i', gradient_png_path,
                            '-filter_complex', fc,
                            '-f', 'webp',
                            '-quality', str(webp_quality),
                            '-loop', str(loop_count),
                            output_path
                        ]
                    else:
                        cmd = [
                            ffmpeg_path, '-y',
                            '-i', source_for_gif,
                            '-vf', ",".join(vf_filters),
                            '-f', 'webp',
                            '-quality', str(webp_quality),
                            '-loop', str(loop_count),
                            output_path
                        ]
                    result = subprocess.run(cmd, capture_output=True, text=True)
                    if result.returncode != 0:
                        raise Exception(f"WebP creation failed: {result.stderr[:200]}")
                else:
                    # FFmpeg lacks libwebp — fall back to Pillow frame assembly
                    create_webp_with_pillow(
                        source_path=source_for_gif,
                        vf_filters=vf_filters,
                        loop_count=loop_count,
                        webp_quality=webp_quality,
                        frame_rate=frame_rate,
                        output_path=output_path,
                        ffmpeg_path=ffmpeg_path,
                        temp_dir=temp_dir
                    )

            elif is_apng:
                # --- APNG path: full 24-bit color, no palette generation needed ---
                if len(keep_segments) > 1:
                    # Multi-segment: source is already trimmed/merged
                    vf_filters = [f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        vf_filters.insert(0, speed_filter)
                else:
                    # Single segment: apply trim filter first
                    vf_filters = [trim_filter, f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        vf_filters.insert(1, speed_filter)

                # Add drawtext after scale (non-gradient text)
                if drawtext_filter:
                    vf_filters.append(drawtext_filter)

                if gradient_png_path:
                    # Gradient text: use filter_complex with overlay
                    vf_str = ",".join(vf_filters)
                    fc = (f"[0:v]{vf_str}[v];"
                          f"[v][1:v]overlay=0:0:"
                          f"enable='between(t\\,{adjusted_text_times[0]:.3f}\\,{adjusted_text_times[1]:.3f})'")
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-i', gradient_png_path,
                        '-filter_complex', fc,
                        '-f', 'apng',
                        '-plays', str(loop_count),
                        output_path
                    ]
                else:
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-vf', ",".join(vf_filters),
                        '-f', 'apng',
                        '-plays', str(loop_count),
                        output_path
                    ]

                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    raise Exception(f"APNG creation failed: {result.stderr[:200]}")

            else:
                # --- GIF path: two-pass palette generation for optimal quality ---
                palette_path = os.path.join(temp_dir, "palette.png")

                # Build filter chain for palette generation
                if len(keep_segments) > 1:
                    # Multi-segment: source is already trimmed/merged
                    filters = [f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        filters.insert(0, speed_filter)
                else:
                    # Single segment: apply trim filter first
                    filters = [trim_filter, f"fps={frame_rate}", scale_filter]
                    if speed_filter:
                        filters.insert(1, speed_filter)  # After trim, before fps

                # Add drawtext BEFORE palettegen so text colors are in the palette
                if drawtext_filter:
                    filters.append(drawtext_filter)

                palette_filters = filters.copy()
                palette_filters.append(f"palettegen=max_colors={color_count}")
                palette_filter = ",".join(palette_filters)

                if gradient_png_path:
                    # For gradient text with GIF: render to intermediate then palette
                    # First pass: use filter_complex to overlay gradient, then palettegen
                    base_str = ",".join(filters)
                    fc_palette = (f"[0:v]{base_str}[v];"
                                  f"[v][1:v]overlay=0:0:"
                                  f"enable='between(t\\,{adjusted_text_times[0]:.3f}\\,{adjusted_text_times[1]:.3f})'[vt];"
                                  f"[vt]palettegen=max_colors={color_count}")
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-i', gradient_png_path,
                        '-filter_complex', fc_palette,
                        palette_path
                    ]
                else:
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-vf', palette_filter,
                        palette_path
                    ]

                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    raise Exception(f"Palette generation failed: {result.stderr[:200]}")

                # Create GIF using palette
                dither_opt = f"dither={dither_method}" if dither_method != "none" else "dither=none"

                base_filter_str = ",".join(filters)

                if gradient_png_path:
                    # Gradient: 3 inputs (video, gradient PNG, palette)
                    filter_complex = (f"[0:v]{base_filter_str}[v];"
                                      f"[v][1:v]overlay=0:0:"
                                      f"enable='between(t\\,{adjusted_text_times[0]:.3f}\\,{adjusted_text_times[1]:.3f})'[vt];"
                                      f"[vt][2:v]paletteuse={dither_opt}")
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-i', gradient_png_path,
                        '-i', palette_path,
                        '-filter_complex', filter_complex,
                        '-loop', str(loop_count),
                        output_path
                    ]
                else:
                    filter_complex = f"[0:v]{base_filter_str}[v];[v][1:v]paletteuse={dither_opt}"
                    cmd = [
                        ffmpeg_path, '-y',
                        '-i', source_for_gif,
                        '-i', palette_path,
                        '-filter_complex', filter_complex,
                        '-loop', str(loop_count),
                        output_path
                    ]

                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    raise Exception(f"GIF creation failed: {result.stderr[:200]}")
            
            # Get output file size
            output_size = os.path.getsize(output_path)
            size_str = format_file_size(output_size)
            
            emit_event(
                EventType.FILE_COMPLETE,
                file=file_id,
                success=True,
                output=output_path,
                size=size_str
            )
            
            return {
                "success": True,
                "file": file_id,
                "output": output_path,
                "size": size_str
            }
            
    except Exception as e:
        emit_event(EventType.FILE_ERROR, file=file_id, error=str(e))
        return {"success": False, "file": file_id, "error": str(e)}


def format_file_size(size_bytes: int) -> str:
    """Format file size in human-readable form."""
    for unit in ['B', 'KB', 'MB', 'GB']:
        if size_bytes < 1024:
            return f"{size_bytes:.1f} {unit}"
        size_bytes /= 1024
    return f"{size_bytes:.1f} TB"


def run_batch(input_config: dict):
    """Run batch GIF conversion based on configuration."""
    files = input_config.get("files", [])
    config = input_config.get("config", {})
    
    # Validate files
    valid_files = []
    for f in files:
        if os.path.isfile(f):
            valid_files.append(f)
        else:
            emit_event(EventType.ERROR, message=f"File not found: {f}")
    
    if not valid_files:
        emit_event(EventType.ERROR, message="No valid files to process")
        return
    
    ffmpeg_path = get_ffmpeg_path()
    
    emit_event(
        EventType.START,
        total_files=len(valid_files),
        ffmpeg_path=ffmpeg_path
    )
    
    results = []
    
    for i, video_path in enumerate(valid_files):
        emit_event(
            EventType.PROGRESS,
            current_file=i + 1,
            total_files=len(valid_files),
            filename=Path(video_path).name
        )
        
        result = process_video_to_gif(video_path, config, ffmpeg_path)
        results.append(result)
    
    successful = sum(1 for r in results if r["success"])
    failed = len(results) - successful
    
    emit_event(
        EventType.COMPLETE,
        total_files=len(valid_files),
        successful=successful,
        failed=failed,
        results=results
    )


def main():
    """Entry point - read config from stdin or file argument."""
    config = None
    
    if len(sys.argv) > 1:
        if sys.argv[1] == "--config" and len(sys.argv) > 2:
            config_path = sys.argv[2]
            try:
                with open(config_path, 'r') as f:
                    config = json.load(f)
            except Exception as e:
                emit_event(EventType.ERROR, message=f"Failed to read config file: {e}")
                sys.exit(1)
        elif sys.argv[1] == "--help":
            print(__doc__)
            sys.exit(0)
    
    if config is None:
        try:
            if not sys.stdin.isatty():
                config = json.load(sys.stdin)
            else:
                emit_event(EventType.ERROR, message="No configuration provided. Use --config <file> or pipe JSON to stdin.")
                sys.exit(1)
        except json.JSONDecodeError as e:
            emit_event(EventType.ERROR, message=f"Invalid JSON input: {e}")
            sys.exit(1)
    
    run_batch(config)


if __name__ == "__main__":
    main()
