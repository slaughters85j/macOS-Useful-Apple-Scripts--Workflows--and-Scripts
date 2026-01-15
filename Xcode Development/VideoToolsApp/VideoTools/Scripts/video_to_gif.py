#!/usr/bin/env python3
"""
Video to GIF Converter - Batch processor for creating animated GIFs from video files.
Designed to be called from a SwiftUI app with JSON configuration.

Features:
- Multi-segment trimming (remove arbitrary sections from the middle)
- Resolution control (scale, fixed width, custom dimensions)
- Frame rate and speed adjustment
- Optimal palette generation for high-quality GIFs
- Configurable dithering and color count
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
        "trim_start": 0,
        "trim_end": null,  // null = use video duration
        "cut_segments": [  // segments to REMOVE
            {"start": 5.0, "end": 8.0},
            {"start": 15.0, "end": 17.0}
        ]
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
    trim_start = config.get('trim_start', 0)
    trim_end = config.get('trim_end')
    cut_segments = config.get('cut_segments', [])
    
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
    output_path = os.path.join(input_dir, f"{input_name}.gif")
    
    # Build scale filter
    scale_filter = build_scale_filter(resolution_config, info['width'], info['height'])
    
    # Speed filter (setpts for video speed)
    speed_filter = f"setpts={1.0/speed_mult}*PTS" if speed_mult != 1.0 else ""
    
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

            # Generate optimal palette
            palette_path = os.path.join(temp_dir, "palette.png")

            # Build filter chain for palette generation
            if len(keep_segments) > 1:
                # Multi-segment: source is already trimmed/merged
                filters = [f"fps={frame_rate}", scale_filter]
                if speed_filter:
                    filters.insert(0, speed_filter)
                filters.append(f"palettegen=max_colors={color_count}")
                palette_filter = ",".join(filters)
            else:
                # Single segment: apply trim filter first
                filters = [trim_filter, f"fps={frame_rate}", scale_filter]
                if speed_filter:
                    filters.insert(1, speed_filter)  # After trim, before fps
                filters.append(f"palettegen=max_colors={color_count}")
                palette_filter = ",".join(filters)

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
            # Dither option
            dither_opt = f"dither={dither_method}" if dither_method != "none" else "dither=none"

            if len(keep_segments) > 1:
                # Multi-segment: source is already trimmed/merged
                base_filters = [f"fps={frame_rate}", scale_filter]
                if speed_filter:
                    base_filters.insert(0, speed_filter)
                base_filter_str = ",".join(base_filters)
                filter_complex = f"[0:v]{base_filter_str}[v];[v][1:v]paletteuse={dither_opt}"
            else:
                # Single segment: apply trim filter in filter_complex
                base_filters = [trim_filter, f"fps={frame_rate}", scale_filter]
                if speed_filter:
                    base_filters.insert(1, speed_filter)  # After trim, before fps
                base_filter_str = ",".join(base_filters)
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
