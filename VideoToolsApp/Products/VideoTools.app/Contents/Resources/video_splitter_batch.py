#!/usr/bin/env python3
"""
Video Splitter Batch - Non-interactive batch processor for video splitting.
Designed to be called from a SwiftUI app with JSON configuration.

Usage:
    echo '{"files": [...], "config": {...}}' | python video_splitter_batch.py
    python video_splitter_batch.py --config config.json

Input JSON Schema:
{
    "files": ["/path/to/video1.mp4", "/path/to/video2.mov"],
    "config": {
        "split_method": "duration" | "segments",
        "split_value": 60,  // seconds if duration, count if segments
        "fps_mode": "single" | "per_file",
        "fps_value": 30,  // used if fps_mode is "single"
        "fps_values": {"video1.mp4": 30, "video2.mov": 24},  // used if fps_mode is "per_file"
        "parallel_jobs": 4
    }
}

Output: JSON lines (one per event) to stdout
"""

import os
import sys
import json
import subprocess
import math
import signal
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, asdict
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


def check_videotoolbox_support(ffmpeg_path: str = "ffmpeg") -> bool:
    """Check if VideoToolbox hardware acceleration is available."""
    try:
        result = subprocess.run([ffmpeg_path, '-encoders'], capture_output=True, text=True)
        return 'h264_videotoolbox' in result.stdout
    except Exception:
        return False


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
        
        return {
            'frame_rate': frame_rate,
            'bit_rate': bit_rate,
            'width': int(video_stream['width']),
            'height': int(video_stream['height']),
            'duration': float(probe['format']['duration']),
            'codec': video_stream.get('codec_name', 'unknown')
        }
    except Exception as e:
        emit_event(EventType.ERROR, message=f"Failed to probe {video_path}: {e}")
        return None


def split_single_segment(args: tuple) -> dict:
    """
    Split a single segment from a video. Designed to run in a separate process.
    
    Args tuple contains:
        (video_path, output_file, start_time, duration, target_fps, bit_rate, 
         width, height, encoder, ffmpeg_path, segment_num, total_segments)
    """
    (video_path, output_file, start_time, duration, target_fps, bit_rate,
     width, height, encoder, ffmpeg_path, segment_num, total_segments, file_id) = args
    
    try:
        cmd = [
            ffmpeg_path,
            '-y',  # Overwrite output
            '-i', video_path,
            '-ss', str(start_time),
            '-t', str(duration),
            '-c:v', encoder,
            '-r', str(target_fps),
            '-b:v', str(bit_rate),
            '-vf', f'scale={width}:{height}',
        ]
        
        # Add encoder-specific options
        if encoder == 'libx264':
            cmd.extend(['-preset', 'medium'])
        
        cmd.extend([
            '-c:a', 'copy',
            '-avoid_negative_ts', '1',
            output_file
        ])
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            return {
                "success": True,
                "file_id": file_id,
                "segment": segment_num,
                "total": total_segments,
                "output": output_file
            }
        else:
            return {
                "success": False,
                "file_id": file_id,
                "segment": segment_num,
                "total": total_segments,
                "error": result.stderr[:500]
            }
    except Exception as e:
        return {
            "success": False,
            "file_id": file_id,
            "segment": segment_num,
            "total": total_segments,
            "error": str(e)
        }


def process_video_file(
    video_path: str,
    split_method: str,
    split_value: float,
    target_fps: float,
    parallel_jobs: int,
    ffmpeg_path: str,
    use_videotoolbox: bool
) -> dict:
    """Process a single video file, splitting it into segments."""
    
    file_id = Path(video_path).name
    emit_event(EventType.FILE_START, file=file_id, path=video_path)
    
    # Probe video
    info = probe_video(video_path, ffmpeg_path)
    if not info:
        emit_event(EventType.FILE_ERROR, file=file_id, error="Failed to probe video")
        return {"success": False, "file": file_id, "error": "Failed to probe video"}
    
    # Calculate segment parameters
    duration = info['duration']
    if split_method == "duration":
        segment_duration = split_value
        num_segments = math.ceil(duration / segment_duration)
    else:  # segments
        num_segments = int(split_value)
        segment_duration = duration / num_segments
    
    # Setup output directory
    input_dir = os.path.dirname(os.path.abspath(video_path)) or '.'
    input_name = Path(video_path).stem
    extension = Path(video_path).suffix
    output_dir = os.path.join(input_dir, f"{input_name}_parts")
    os.makedirs(output_dir, exist_ok=True)
    
    encoder = 'h264_videotoolbox' if use_videotoolbox else 'libx264'
    
    # Build segment tasks
    segment_tasks = []
    for i in range(num_segments):
        start_time = i * segment_duration
        output_file = os.path.join(output_dir, f"{input_name}_part{i+1:03d}{extension}")
        
        segment_tasks.append((
            video_path, output_file, start_time, segment_duration, target_fps,
            info['bit_rate'], info['width'], info['height'], encoder, ffmpeg_path,
            i + 1, num_segments, file_id
        ))
    
    # Process segments (parallel within this file's allocation)
    completed = 0
    errors = []
    outputs = []
    
    # Use at most parallel_jobs workers for this file's segments
    workers = min(parallel_jobs, len(segment_tasks))
    
    with ProcessPoolExecutor(max_workers=workers) as executor:
        futures = {executor.submit(split_single_segment, task): task for task in segment_tasks}
        
        for future in as_completed(futures):
            result = future.result()
            completed += 1
            
            if result["success"]:
                outputs.append(result["output"])
                emit_event(
                    EventType.SEGMENT_COMPLETE,
                    file=file_id,
                    segment=result["segment"],
                    total=result["total"],
                    output=result["output"]
                )
            else:
                errors.append(result["error"])
                emit_event(
                    EventType.FILE_ERROR,
                    file=file_id,
                    segment=result["segment"],
                    error=result["error"]
                )
    
    success = len(errors) == 0
    emit_event(
        EventType.FILE_COMPLETE,
        file=file_id,
        success=success,
        segments_completed=len(outputs),
        segments_total=num_segments,
        output_dir=output_dir
    )
    
    return {
        "success": success,
        "file": file_id,
        "output_dir": output_dir,
        "segments": len(outputs),
        "errors": errors
    }


def run_batch(config: dict):
    """
    Run batch video splitting based on configuration.
    
    Config structure:
    {
        "files": ["/path/to/video1.mp4", ...],
        "config": {
            "split_method": "duration" | "segments",
            "split_value": 60,
            "fps_mode": "single" | "per_file",
            "fps_value": 30,
            "fps_values": {"filename.mp4": 24, ...},
            "parallel_jobs": 4
        }
    }
    """
    files = config.get("files", [])
    settings = config.get("config", {})
    
    split_method = settings.get("split_method", "duration")
    split_value = settings.get("split_value", 60)
    fps_mode = settings.get("fps_mode", "single")
    fps_value = settings.get("fps_value", 30)
    fps_values = settings.get("fps_values", {})
    parallel_jobs = settings.get("parallel_jobs", 4)
    
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
    
    # Setup
    ffmpeg_path = get_ffmpeg_path()
    use_videotoolbox = check_videotoolbox_support(ffmpeg_path)
    
    emit_event(
        EventType.START,
        total_files=len(valid_files),
        split_method=split_method,
        split_value=split_value,
        fps_mode=fps_mode,
        parallel_jobs=parallel_jobs,
        hardware_acceleration=use_videotoolbox,
        ffmpeg_path=ffmpeg_path
    )
    
    results = []
    
    # Process files serially (parallelism is within each file's segments)
    # This prevents I/O thrashing from too many simultaneous reads
    for i, video_path in enumerate(valid_files):
        filename = Path(video_path).name
        
        # Determine FPS for this file
        if fps_mode == "per_file" and filename in fps_values:
            target_fps = fps_values[filename]
        else:
            target_fps = fps_value
        
        emit_event(
            EventType.PROGRESS,
            current_file=i + 1,
            total_files=len(valid_files),
            filename=filename
        )
        
        result = process_video_file(
            video_path=video_path,
            split_method=split_method,
            split_value=split_value,
            target_fps=target_fps,
            parallel_jobs=parallel_jobs,
            ffmpeg_path=ffmpeg_path,
            use_videotoolbox=use_videotoolbox
        )
        results.append(result)
    
    # Final summary
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
    
    # Run the batch processor
    run_batch(config)


if __name__ == "__main__":
    main()
