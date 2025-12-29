#!/usr/bin/env python3
"""
Video/Audio Separator Batch - Non-interactive batch processor for separating
video and audio streams. Designed to be called from a SwiftUI app with JSON configuration.

Usage:
    echo '{"files": [...], "config": {...}}' | python video_audio_separator_batch.py
    python video_audio_separator_batch.py --config config.json

Input JSON Schema:
{
    "files": ["/path/to/video1.mp4", "/path/to/video2.mov"],
    "config": {
        "sample_rate_mode": "single" | "per_file",
        "sample_rate": 48000,
        "sample_rates": {"video1.mp4": 44100, "video2.mov": 48000},
        "parallel_jobs": 4
    }
}

Output: JSON lines (one per event) to stdout
"""

import os
import sys
import json
import subprocess
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Optional
from enum import Enum

sys.stdout.reconfigure(line_buffering=True)


class EventType(Enum):
    START = "start"
    PROGRESS = "progress"
    FILE_START = "file_start"
    FILE_COMPLETE = "file_complete"
    FILE_ERROR = "file_error"
    STREAM_COMPLETE = "stream_complete"
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
        audio_stream = next(
            (s for s in probe['streams'] if s['codec_type'] == 'audio'), None
        )
        
        if not video_stream:
            return None
        
        # Frame rate
        fps_str = video_stream.get('avg_frame_rate', '30/1')
        if '/' in fps_str:
            num, den = map(float, fps_str.split('/'))
            frame_rate = num / den if den else 30.0
        else:
            frame_rate = float(fps_str) if fps_str else 30.0
        
        # Bit rate
        bit_rate = None
        if 'bit_rate' in video_stream:
            bit_rate = int(video_stream['bit_rate'])
        elif 'bit_rate' in probe.get('format', {}):
            bit_rate = int(probe['format']['bit_rate'])
        else:
            bit_rate = 2_000_000
        
        # Audio info
        audio_info = None
        if audio_stream:
            audio_info = {
                'sample_rate': int(audio_stream.get('sample_rate', 48000)),
                'channels': int(audio_stream.get('channels', 2)),
                'codec': audio_stream.get('codec_name', 'unknown')
            }
        
        return {
            'frame_rate': frame_rate,
            'bit_rate': bit_rate,
            'width': int(video_stream['width']),
            'height': int(video_stream['height']),
            'codec': video_stream.get('codec_name', 'unknown'),
            'has_audio': audio_stream is not None,
            'audio_info': audio_info
        }
    except Exception as e:
        emit_event(EventType.ERROR, message=f"Failed to probe {video_path}: {e}")
        return None


def extract_video_stream(args: tuple) -> dict:
    """Extract video stream (no audio) from a video file."""
    (video_path, output_file, frame_rate, bit_rate, encoder, ffmpeg_path, file_id) = args
    
    try:
        cmd = [
            ffmpeg_path,
            '-y',
            '-i', video_path,
            '-c:v', encoder,
            '-r', str(frame_rate),
            '-b:v', str(bit_rate),
            '-an',  # No audio
        ]
        
        if encoder == 'libx264':
            cmd.extend(['-preset', 'medium'])
        
        cmd.append(output_file)
        
        result = subprocess.run(cmd, capture_output=True, text=True)
        
        if result.returncode == 0:
            return {"success": True, "file_id": file_id, "stream": "video", "output": output_file}
        else:
            return {"success": False, "file_id": file_id, "stream": "video", "error": result.stderr[:500]}
    except Exception as e:
        return {"success": False, "file_id": file_id, "stream": "video", "error": str(e)}


def extract_audio_stream(args: tuple) -> dict:
    """Extract audio stream as WAV from a video file."""
    (video_path, output_file, sample_rate, ffmpeg_path, file_id) = args
    
    # Try multiple extraction methods
    methods = [
        # Method 1: Standard PCM
        [ffmpeg_path, '-y', '-analyzeduration', '100M', '-probesize', '100M',
         '-i', video_path, '-vn', '-acodec', 'pcm_s16le', '-ar', str(sample_rate), output_file],
        # Method 2: Float PCM
        [ffmpeg_path, '-y', '-i', video_path, '-vn', '-acodec', 'pcm_f32le', 
         '-ar', str(sample_rate), output_file],
        # Method 3: Format auto-detect
        [ffmpeg_path, '-y', '-f', 'mp4', '-i', video_path, '-vn', '-f', 'wav', output_file],
    ]
    
    for cmd in methods:
        try:
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode == 0 and os.path.exists(output_file) and os.path.getsize(output_file) > 1000:
                return {"success": True, "file_id": file_id, "stream": "audio", "output": output_file}
        except Exception:
            continue
    
    # All methods failed - try copying raw audio stream
    raw_output = output_file.replace('.wav', '.aac')
    try:
        cmd = [ffmpeg_path, '-y', '-i', video_path, '-vn', '-acodec', 'copy', raw_output]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0 and os.path.exists(raw_output) and os.path.getsize(raw_output) > 1000:
            return {
                "success": True, 
                "file_id": file_id, 
                "stream": "audio", 
                "output": raw_output,
                "warning": "Could not convert to WAV, saved as AAC"
            }
    except Exception:
        pass
    
    return {
        "success": False, 
        "file_id": file_id, 
        "stream": "audio", 
        "error": "All audio extraction methods failed"
    }


def process_single_file(args: tuple) -> dict:
    """Process a single video file - extract both video and audio streams."""
    (video_path, sample_rate, ffmpeg_path, use_videotoolbox) = args
    
    file_id = Path(video_path).name
    
    # Probe video
    info = probe_video(video_path, ffmpeg_path)
    if not info:
        return {"success": False, "file": file_id, "error": "Failed to probe video"}
    
    # Setup output directory
    input_dir = os.path.dirname(os.path.abspath(video_path)) or '.'
    input_name = Path(video_path).stem
    output_dir = os.path.join(input_dir, f"{input_name}_separated")
    os.makedirs(output_dir, exist_ok=True)
    
    video_output = os.path.join(output_dir, f"{input_name}_video.mp4")
    audio_output = os.path.join(output_dir, f"{input_name}_audio.wav")
    
    encoder = 'h264_videotoolbox' if use_videotoolbox else 'libx264'
    
    results = {"file": file_id, "output_dir": output_dir, "video": None, "audio": None}
    
    # Extract video
    video_result = extract_video_stream((
        video_path, video_output, info['frame_rate'], info['bit_rate'], 
        encoder, ffmpeg_path, file_id
    ))
    results["video"] = video_result
    
    # Extract audio if present
    if info['has_audio']:
        audio_result = extract_audio_stream((
            video_path, audio_output, sample_rate, ffmpeg_path, file_id
        ))
        results["audio"] = audio_result
    else:
        results["audio"] = {"success": True, "skipped": True, "reason": "No audio stream"}
    
    results["success"] = (
        results["video"]["success"] and 
        (results["audio"].get("success", False) or results["audio"].get("skipped", False))
    )
    
    return results


def run_batch(config: dict):
    """
    Run batch video/audio separation based on configuration.
    
    Config structure:
    {
        "files": ["/path/to/video1.mp4", ...],
        "config": {
            "sample_rate_mode": "single" | "per_file",
            "sample_rate": 48000,
            "sample_rates": {"filename.mp4": 44100, ...},
            "parallel_jobs": 4
        }
    }
    """
    files = config.get("files", [])
    settings = config.get("config", {})
    
    sample_rate_mode = settings.get("sample_rate_mode", "single")
    sample_rate = settings.get("sample_rate", 48000)
    sample_rates = settings.get("sample_rates", {})
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
        sample_rate_mode=sample_rate_mode,
        default_sample_rate=sample_rate,
        parallel_jobs=parallel_jobs,
        hardware_acceleration=use_videotoolbox,
        ffmpeg_path=ffmpeg_path
    )
    
    # Build task list
    tasks = []
    for video_path in valid_files:
        filename = Path(video_path).name
        
        # Determine sample rate for this file
        if sample_rate_mode == "per_file" and filename in sample_rates:
            file_sample_rate = sample_rates[filename]
        else:
            file_sample_rate = sample_rate
        
        tasks.append((video_path, file_sample_rate, ffmpeg_path, use_videotoolbox))
    
    results = []
    
    # Process files in parallel
    with ProcessPoolExecutor(max_workers=parallel_jobs) as executor:
        futures = {executor.submit(process_single_file, task): task[0] for task in tasks}
        
        completed = 0
        for future in as_completed(futures):
            video_path = futures[future]
            file_id = Path(video_path).name
            completed += 1
            
            try:
                result = future.result()
                results.append(result)
                
                if result["success"]:
                    emit_event(
                        EventType.FILE_COMPLETE,
                        file=file_id,
                        success=True,
                        output_dir=result["output_dir"],
                        video=result["video"],
                        audio=result["audio"],
                        progress=f"{completed}/{len(valid_files)}"
                    )
                else:
                    emit_event(
                        EventType.FILE_ERROR,
                        file=file_id,
                        video=result.get("video"),
                        audio=result.get("audio"),
                        error=result.get("error", "Unknown error")
                    )
            except Exception as e:
                emit_event(EventType.FILE_ERROR, file=file_id, error=str(e))
                results.append({"success": False, "file": file_id, "error": str(e)})
    
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
