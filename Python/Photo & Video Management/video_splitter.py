#!/usr/bin/env python3
"""
Video Splitter - Splits a video into segments while preserving bit rate and resolution,
with customizable frame rate. Optimized for Apple Silicon with VideoToolbox support.

Any Python version should work. Tested with Python 3.12.3

Usage:
    python video_splitter.py
    Then follow the interactive prompts.

Example Output:

Welcome to Video Splitter!

Enter the path to your video file (does not require quotations around path): my video.mp4

Analyzing video: my video.mp4

Video information:
  Current frame rate: 29.97 fps
  Current bit rate: 8.50 Mbps
  Resolution: 1920x1080
  Duration: 300.50 seconds

Do you want to split by (1) number of segments or (2) duration per segment? Enter 1 or 2: 2

Enter the duration (in seconds) for each segment: 60

What frame rate would you like for the output? (e.g., 30): 30

Settings Summary:
  Input file: my video.mp4
  Output directory: my video_parts
  Segment duration: 60.00 seconds
  Number of segments: 6
  Target frame rate: 30 fps
  Hardware acceleration: Available

Proceed with these settings? (y/n): y
"""

import os
import subprocess
import math
import ffmpeg
from pathlib import Path

def check_videotoolbox_support():
    """
    Check if VideoToolbox hardware acceleration is available.
    """
    try:
        result = subprocess.run(['ffmpeg', '-encoders'], capture_output=True, text=True)
        return 'h264_videotoolbox' in result.stdout
    except Exception:
        return False

def clean_path(path):
    """
    Clean user input path by removing quotes and extra spaces.
    """
    return path.strip().strip('"\'').strip()

def get_video_info(video_path):
    """
    Get video metadata including frame rate, bit rate, and resolution.
    """
    try:
        probe = ffmpeg.probe(video_path)
        video_stream = next((stream for stream in probe['streams'] 
                             if stream['codec_type'] == 'video'), None)
        
        if video_stream is None:
            raise Exception("No video stream found")
            
        # Extract frame rate
        frame_rate = eval(video_stream.get('avg_frame_rate', '0/1'))
        if frame_rate == 0:
            frame_rate = eval(video_stream.get('r_frame_rate', '30/1'))
            
        # Extract resolution
        width = int(video_stream['width'])
        height = int(video_stream['height'])
        
        # Extract bit rate (may be in format_tags or in separate key)
        if 'bit_rate' in video_stream:
            bit_rate = int(video_stream['bit_rate'])
        elif 'tags' in video_stream and 'BPS' in video_stream['tags']:
            bit_rate = int(video_stream['tags']['BPS'])
        elif 'bit_rate' in probe['format']:
            bit_rate = int(probe['format']['bit_rate'])
        else:
            # Default to a reasonable value if bitrate cannot be determined
            bit_rate = 2000000  # 2 Mbps
            print(f"Warning: Could not determine bit rate, using default: 2 Mbps")
        
        # Get duration
        duration = float(probe['format']['duration'])
        
        return {
            'frame_rate': frame_rate,
            'bit_rate': bit_rate,
            'width': width,
            'height': height,
            'duration': duration
        }
    except Exception as e:
        print(f"Error getting video info: {str(e)}")
        return None

def split_video(video_path, output_dir, segment_duration, video_info):
    """
    Split video into segments of specified duration, encoding at target fps while preserving other parameters.
    Uses VideoToolbox acceleration if available.
    """
    # Create output directory if it doesn't exist
    os.makedirs(output_dir, exist_ok=True)
    
    # Get base filename without extension
    base_name = Path(video_path).stem
    extension = Path(video_path).suffix
    
    # Calculate number of segments
    total_duration = video_info['duration']
    num_segments = math.ceil(total_duration / segment_duration)
    
    # Check for VideoToolbox support
    use_videotoolbox = check_videotoolbox_support()
    encoder = 'h264_videotoolbox' if use_videotoolbox else 'libx264'
    
    print(f"\nVideo info:")
    print(f"  Original frame rate: {video_info['frame_rate']} fps")
    print(f"  Target frame rate: {video_info['target_fps']} fps")
    print(f"  Bit rate: {video_info['bit_rate'] / 1_000_000:.2f} Mbps")
    print(f"  Resolution: {video_info['width']}x{video_info['height']}")
    print(f"  Duration: {total_duration:.2f} seconds")
    print(f"  Splitting into {num_segments} segments of {segment_duration:.2f} seconds each")
    print(f"  Using encoder: {encoder} {'(Hardware accelerated)' if use_videotoolbox else '(Software)'}")
    
    for i in range(num_segments):
        start_time = i * segment_duration
        output_file = os.path.join(output_dir, f"{base_name}_part{i+1:03d}{extension}")
        
        try:
            # Form the FFmpeg command with hardware acceleration if available
            cmd = [
                'ffmpeg',
                '-i', video_path,
                '-ss', str(start_time),
                '-t', str(segment_duration),
                '-c:v', encoder,
                '-r', str(video_info['target_fps']),
                '-b:v', str(video_info['bit_rate']),
                '-vf', f'scale={video_info["width"]}:{video_info["height"]}',
            ]
            
            # Add encoder-specific options
            if not use_videotoolbox:
                cmd.extend(['-preset', 'medium'])  # Only for libx264
            
            # Add common options
            cmd.extend([
                '-c:a', 'copy',
                '-avoid_negative_ts', '1',
                output_file
            ])
            
            print(f"\nCreating segment {i+1}/{num_segments}: {output_file}")
            subprocess.run(cmd, check=True)
            
        except subprocess.CalledProcessError as e:
            print(f"Error creating segment {i+1}: {str(e)}")
            continue
    
    print(f"\nVideo splitting complete. Output files in: {output_dir}")  # end split_video

def main():
    """
    Interactive main function to get user input for video processing.
    """
    print("Welcome to Video Splitter!")
    
    # Get video path
    while True:
        video_path = clean_path(input("\nEnter the path to your video file: "))
        if os.path.isfile(video_path):
            break
        print(f"Error: File '{video_path}' does not exist. Please try again.")
    
    # Get video information
    print(f"\nAnalyzing video: {video_path}")
    video_info = get_video_info(video_path)
    if not video_info:
        return
    
    # Display video information
    print("\nVideo information:")
    print(f"  Current frame rate: {video_info['frame_rate']} fps")
    print(f"  Current bit rate: {video_info['bit_rate'] / 1_000_000:.2f} Mbps")
    print(f"  Resolution: {video_info['width']}x{video_info['height']}")
    print(f"  Duration: {video_info['duration']:.2f} seconds")
    
    # Get split method
    while True:
        split_method = input("\nDo you want to split by (1) number of segments or (2) duration per segment? Enter 1 or 2: ").strip()
        if split_method in ['1', '2']:
            break
        print("Please enter either 1 or 2.")
    
    # Get split parameters based on method
    if split_method == '1':
        while True:
            try:
                num_segments = int(input("\nHow many segments would you like to split the video into? "))
                if num_segments > 0:
                    segment_duration = math.ceil(video_info['duration'] / num_segments)
                    break
                print("Please enter a positive number.")
            except ValueError:
                print("Please enter a valid number.")
    else:  # split_method == '2'
        while True:
            try:
                segment_duration = float(input("\nEnter the duration (in seconds) for each segment: "))
                if segment_duration > 0:
                    num_segments = math.ceil(video_info['duration'] / segment_duration)
                    break
                print("Please enter a positive number.")
            except ValueError:
                print("Please enter a valid number.")
    
    # Get desired frame rate
    while True:
        try:
            target_fps = float(input("\nWhat frame rate would you like for the output? (e.g., 30): "))
            if target_fps > 0:
                break
            print("Please enter a positive number.")
        except ValueError:
            print("Please enter a valid number.")
    
    # Set output directory
    input_dir = os.path.dirname(os.path.abspath(video_path)) or '.'
    input_name = Path(video_path).stem
    output_dir = os.path.join(input_dir, f"{input_name}_parts")
    
    # Confirm settings with user
    print("\nSettings Summary:")
    print(f"  Input file: {video_path}")
    print(f"  Output directory: {output_dir}")
    if split_method == '1':
        print(f"  Number of segments: {num_segments}")
        print(f"  Segment duration: {segment_duration:.2f} seconds")
    else:
        print(f"  Segment duration: {segment_duration:.2f} seconds")
        print(f"  Number of segments: {num_segments}")
    print(f"  Target frame rate: {target_fps} fps")
    print(f"  Hardware acceleration: {'Available' if check_videotoolbox_support() else 'Not available'}")
    
    proceed = input("\nProceed with these settings? (y/n): ").lower().strip()
    if proceed != 'y':
        print("Operation cancelled.")
        return
    
    # Split video
    video_info['target_fps'] = target_fps  # Add target fps to video_info
    split_video(video_path, output_dir, segment_duration, video_info)


if __name__ == "__main__":
    main()  # end main