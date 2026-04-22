#!/usr/bin/env python3
"""
Video Merger - Merges multiple video files into a single output.
Designed to be called from a SwiftUI app with JSON configuration.

Usage:
    echo '{"files": [...], "config": {...}}' | python video_merger.py
    python video_merger.py --config config.json

Input JSON Schema:
{
    "files": ["/path/to/video1.mp4", "/path/to/video2.mov"],
    "config": {
        "output_filename": "merged_output",
        "aspect_mode": "letterbox" | "crop_fill",
        "output_codec": "copy" | "h264" | "hevc",
        "quality_mode": "quality" | "match_bitrate",
        "quality_value": 65,
        "fps_value": 30,
        "output_dir": "/path/to/output"
    }
}

Output: JSON lines (one per event) to stdout
"""

import os
import sys
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Optional
from enum import Enum

# Ensure unbuffered output for real-time progress
sys.stdout.reconfigure(line_buffering=True)


class EventType(Enum):
    START = "start"
    PROGRESS = "progress"
    FILE_START = "file_start"
    FILE_COMPLETE = "file_complete"
    FILE_ERROR = "file_error"
    SEGMENT_START = "segment_start"
    SEGMENT_COMPLETE = "segment_complete"
    COMPLETE = "complete"
    ERROR = "error"


def emit_event(event_type: EventType, **kwargs):
    """Emit a JSON event to stdout for the Swift app to consume."""
    event = {"event": event_type.value, **kwargs}
    print(json.dumps(event), flush=True)


def get_ffmpeg_path() -> str:
    """Get the ffmpeg binary path."""
    common_paths = [
        "/usr/local/bin/ffmpeg",
        "/opt/homebrew/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]
    for path in common_paths:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return "ffmpeg"


def check_videotoolbox_support(ffmpeg_path: str = "ffmpeg") -> bool:
    """Check if VideoToolbox H.264 hardware acceleration is available."""
    try:
        result = subprocess.run([ffmpeg_path, '-encoders'], capture_output=True, text=True)
        return 'h264_videotoolbox' in result.stdout
    except Exception:
        return False


def check_hevc_videotoolbox_support(ffmpeg_path: str = "ffmpeg") -> bool:
    """Check if VideoToolbox HEVC hardware acceleration is available."""
    try:
        result = subprocess.run([ffmpeg_path, '-encoders'], capture_output=True, text=True)
        return 'hevc_videotoolbox' in result.stdout
    except Exception:
        return False


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

        audio_stream = next(
            (s for s in probe['streams'] if s['codec_type'] == 'audio'), None
        )

        # Extract frame rate
        fps_str = video_stream.get('avg_frame_rate', '30/1')
        if '/' in fps_str:
            num, den = map(float, fps_str.split('/'))
            frame_rate = num / den if den else 30.0
        else:
            frame_rate = float(fps_str) if fps_str else 30.0

        # Extract bit rate
        bit_rate = None
        if 'bit_rate' in video_stream:
            bit_rate = int(video_stream['bit_rate'])
        elif 'bit_rate' in probe.get('format', {}):
            bit_rate = int(probe['format']['bit_rate'])
        else:
            bit_rate = 2_000_000  # 2 Mbps default

        # Audio info
        audio_sample_rate = int(audio_stream.get('sample_rate', 44100)) if audio_stream else None
        audio_channels = int(audio_stream.get('channels', 2)) if audio_stream else None

        return {
            'frame_rate': frame_rate,
            'bit_rate': bit_rate,
            'width': int(video_stream['width']),
            'height': int(video_stream['height']),
            'duration': float(probe['format']['duration']),
            'codec': video_stream.get('codec_name', 'unknown'),
            'has_audio': audio_stream is not None,
            'audio_codec': audio_stream.get('codec_name') if audio_stream else None,
            'audio_sample_rate': audio_sample_rate,
            'audio_channels': audio_channels,
        }
    except Exception as e:
        emit_event(EventType.ERROR, message=f"Failed to probe {video_path}: {e}")
        return None


def select_encoder(output_codec: str, quality_mode: str, quality_value: float,
                   bit_rate: int, ffmpeg_path: str) -> tuple:
    """
    Select encoder and build quality/bitrate flags based on codec choice.

    Returns: (encoder_name: str, extra_flags: list[str], is_copy: bool)
    """
    if output_codec == "copy":
        return ("copy", [], True)

    if output_codec == "hevc":
        if check_hevc_videotoolbox_support(ffmpeg_path):
            encoder = "hevc_videotoolbox"
            if quality_mode == "quality":
                flags = ["-q:v", str(int(quality_value)), "-tag:v", "hvc1"]
            else:
                flags = ["-b:v", str(bit_rate), "-tag:v", "hvc1"]
        else:
            encoder = "libx265"
            crf = round(51 - (quality_value * 51 / 100))
            if quality_mode == "quality":
                flags = ["-crf", str(crf), "-preset", "medium", "-tag:v", "hvc1"]
            else:
                flags = ["-b:v", str(bit_rate), "-preset", "medium", "-tag:v", "hvc1"]
        return (encoder, flags, False)

    # h264
    if check_videotoolbox_support(ffmpeg_path):
        encoder = "h264_videotoolbox"
        if quality_mode == "quality":
            flags = ["-q:v", str(int(quality_value))]
        else:
            flags = ["-b:v", str(bit_rate)]
    else:
        encoder = "libx264"
        crf = round(51 - (quality_value * 51 / 100))
        if quality_mode == "quality":
            flags = ["-crf", str(crf), "-preset", "medium"]
        else:
            flags = ["-b:v", str(bit_rate), "-preset", "medium"]
    return (encoder, flags, False)


def inputs_are_compatible(probes: list) -> bool:
    """Check if all inputs have compatible codec, resolution, and frame rate for stream copy."""
    if not probes:
        return False

    ref = probes[0]
    for p in probes[1:]:
        if p['codec'] != ref['codec']:
            return False
        if p['width'] != ref['width'] or p['height'] != ref['height']:
            return False
        if abs(p['frame_rate'] - ref['frame_rate']) > 0.5:
            return False
    return True


def merge_with_copy(files: list, output_path: str, ffmpeg_path: str) -> dict:
    """Merge files using concat demuxer (stream copy, no re-encode)."""
    # Create temporary concat list file
    concat_file = None
    try:
        with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False) as f:
            concat_file = f.name
            for video_path in files:
                # Escape single quotes in paths for ffmpeg concat format
                escaped = video_path.replace("'", "'\\''")
                f.write(f"file '{escaped}'\n")

        cmd = [
            ffmpeg_path,
            '-y',
            '-f', 'concat',
            '-safe', '0',
            '-i', concat_file,
            '-c', 'copy',
            output_path
        ]

        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode == 0:
            return {"success": True, "output": output_path}
        else:
            return {"success": False, "error": result.stderr[:500]}
    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        if concat_file and os.path.exists(concat_file):
            os.unlink(concat_file)


def merge_with_reencode(files: list, probes: list, output_path: str,
                        aspect_mode: str, target_fps: float,
                        encoder: str, encoder_flags: list,
                        ffmpeg_path: str) -> dict:
    """Merge files using filter_complex with re-encoding for resolution/fps normalization."""

    # Determine target resolution (max width and height across all inputs)
    # Make dimensions even (required by most encoders)
    target_w = max(p['width'] for p in probes)
    target_h = max(p['height'] for p in probes)
    target_w = target_w + (target_w % 2)  # ensure even
    target_h = target_h + (target_h % 2)  # ensure even

    n = len(files)

    # Build input arguments
    input_args = []
    for f in files:
        input_args.extend(['-i', f])

    # Build filter_complex string
    filter_parts = []
    concat_inputs = []

    # Determine target audio sample rate (use max found)
    max_sample_rate = 44100
    for p in probes:
        if p['audio_sample_rate'] and p['audio_sample_rate'] > max_sample_rate:
            max_sample_rate = p['audio_sample_rate']

    for i, probe in enumerate(probes):
        # Video filter chain
        if aspect_mode == "crop_fill":
            # Scale up to fill, then crop to exact dimensions
            vf = (
                f"[{i}:v]scale={target_w}:{target_h}:"
                f"force_original_aspect_ratio=increase,"
                f"crop={target_w}:{target_h},"
                f"setsar=1,fps={target_fps}[v{i}]"
            )
        else:
            # Letterbox: scale down to fit, then pad with black bars
            vf = (
                f"[{i}:v]scale={target_w}:{target_h}:"
                f"force_original_aspect_ratio=decrease,"
                f"pad={target_w}:{target_h}:(ow-iw)/2:(oh-ih)/2:color=black,"
                f"setsar=1,fps={target_fps}[v{i}]"
            )
        filter_parts.append(vf)

        # Audio filter chain
        if probe['has_audio']:
            af = (
                f"[{i}:a]aresample={max_sample_rate},"
                f"aformat=channel_layouts=stereo[a{i}]"
            )
        else:
            # Generate silence for inputs without audio
            af = (
                f"anullsrc=r={max_sample_rate}:cl=stereo[silence{i}]; "
                f"[silence{i}]atrim=duration={probe['duration']}[a{i}]"
            )
        filter_parts.append(af)

        concat_inputs.append(f"[v{i}][a{i}]")

    # Concat filter
    concat_str = "".join(concat_inputs)
    filter_parts.append(f"{concat_str}concat=n={n}:v=1:a=1[outv][outa]")

    filter_complex = "; ".join(filter_parts)

    # Build full command
    cmd = [ffmpeg_path, '-y']
    cmd.extend(input_args)
    cmd.extend(['-filter_complex', filter_complex])
    cmd.extend(['-map', '[outv]', '-map', '[outa]'])
    cmd.extend(['-c:v', encoder])
    cmd.extend(encoder_flags)
    cmd.extend(['-c:a', 'aac', '-b:a', '192k'])
    cmd.append(output_path)

    try:
        result = subprocess.run(cmd, capture_output=True, text=True)

        if result.returncode == 0:
            return {"success": True, "output": output_path}
        else:
            return {"success": False, "error": result.stderr[:1000]}
    except Exception as e:
        return {"success": False, "error": str(e)}


def get_unique_output_path(output_path: str) -> str:
    """If output_path already exists, append _1, _2, etc. to avoid overwriting."""
    if not os.path.exists(output_path):
        return output_path

    base = Path(output_path).stem
    ext = Path(output_path).suffix
    parent = Path(output_path).parent
    counter = 1
    while True:
        candidate = parent / f"{base}_{counter}{ext}"
        if not candidate.exists():
            return str(candidate)
        counter += 1


def run_merge(config: dict):
    """
    Run video merge based on configuration.

    Config structure:
    {
        "files": ["/path/to/video1.mp4", ...],
        "config": {
            "output_filename": "merged_output",
            "aspect_mode": "letterbox" | "crop_fill",
            "output_codec": "copy" | "h264" | "hevc",
            "quality_mode": "quality" | "match_bitrate",
            "quality_value": 65,
            "fps_value": 30,
            "output_dir": "/path/to/output"
        }
    }
    """
    files = config.get("files", [])
    settings = config.get("config", {})

    output_filename = settings.get("output_filename", "merged_output")
    aspect_mode = settings.get("aspect_mode", "letterbox")
    output_codec = settings.get("output_codec", "h264")
    quality_mode = settings.get("quality_mode", "quality")
    quality_value = settings.get("quality_value", 65)
    fps_value = settings.get("fps_value", 30)
    output_dir = settings.get("output_dir", ".")

    # Validate files
    valid_files = []
    for f in files:
        if os.path.isfile(f):
            valid_files.append(f)
        else:
            emit_event(EventType.ERROR, message=f"File not found: {f}")

    if len(valid_files) < 2:
        emit_event(EventType.ERROR, message="Need at least 2 valid files to merge")
        return

    ffmpeg_path = get_ffmpeg_path()

    emit_event(
        EventType.START,
        total_files=len(valid_files),
        aspect_mode=aspect_mode,
        output_codec=output_codec,
        quality_mode=quality_mode,
        ffmpeg_path=ffmpeg_path
    )

    # Probe all inputs
    emit_event(EventType.FILE_START, file="merge", path="merge")

    probes = []
    for i, video_path in enumerate(valid_files):
        filename = Path(video_path).name
        emit_event(
            EventType.SEGMENT_START,
            file="merge",
            segment=i + 1,
            total=len(valid_files)
        )

        info = probe_video(video_path, ffmpeg_path)
        if not info:
            emit_event(
                EventType.FILE_ERROR,
                file="merge",
                error=f"Failed to probe: {filename}"
            )
            emit_event(EventType.COMPLETE, total_files=len(valid_files), successful=0, failed=1)
            return
        probes.append(info)

        emit_event(
            EventType.SEGMENT_COMPLETE,
            file="merge",
            segment=i + 1,
            total=len(valid_files),
            output=filename
        )

    # Ensure output directory exists
    os.makedirs(output_dir, exist_ok=True)

    # Determine output extension
    extension = ".mp4"
    if output_codec == "copy":
        # Use extension of first file when stream copying
        extension = Path(valid_files[0]).suffix

    output_path = os.path.join(output_dir, f"{output_filename}{extension}")
    output_path = get_unique_output_path(output_path)

    # Perform merge
    if output_codec == "copy":
        # Validate compatibility for stream copy
        if not inputs_are_compatible(probes):
            emit_event(
                EventType.FILE_ERROR,
                file="merge",
                error="Stream copy requires all inputs to have identical codec, resolution, and frame rate. Use H.264 or HEVC instead."
            )
            emit_event(EventType.COMPLETE, total_files=len(valid_files), successful=0, failed=1)
            return

        result = merge_with_copy(valid_files, output_path, ffmpeg_path)
    else:
        # Determine average bit rate across inputs for match_bitrate mode
        avg_bitrate = sum(p['bit_rate'] for p in probes) // len(probes)

        encoder, encoder_flags, _ = select_encoder(
            output_codec, quality_mode, quality_value, avg_bitrate, ffmpeg_path
        )

        result = merge_with_reencode(
            files=valid_files,
            probes=probes,
            output_path=output_path,
            aspect_mode=aspect_mode,
            target_fps=fps_value,
            encoder=encoder,
            encoder_flags=encoder_flags,
            ffmpeg_path=ffmpeg_path
        )

    if result["success"]:
        emit_event(
            EventType.FILE_COMPLETE,
            file="merge",
            success=True,
            segments_completed=len(valid_files),
            segments_total=len(valid_files),
            output_dir=output_dir
        )
        emit_event(
            EventType.COMPLETE,
            total_files=len(valid_files),
            successful=1,
            failed=0,
            results=[result]
        )
    else:
        emit_event(
            EventType.FILE_ERROR,
            file="merge",
            error=result["error"]
        )
        emit_event(
            EventType.COMPLETE,
            total_files=len(valid_files),
            successful=0,
            failed=1,
            results=[result]
        )


def main():
    """Entry point - read config from stdin or file argument."""
    config = None

    # Check for config file argument
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

    # If no config from args, try stdin
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

    # Run the merger
    run_merge(config)


if __name__ == "__main__":
    main()
