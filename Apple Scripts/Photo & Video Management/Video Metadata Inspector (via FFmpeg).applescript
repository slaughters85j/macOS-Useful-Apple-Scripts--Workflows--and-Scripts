(*
  Video Metadata Inspector (via FFmpeg) — macOS AppleScript
  -------------------------------------------------------------------------
  Description:
  Takes the first Finder-selected file (video), invokes FFmpeg to read
  stream metadata, parses key fields (codec type, average FPS, bitrate,
  and resolution), and displays a formatted summary dialog.

  Behavior:
  - Expects at least one file passed in (e.g., from a Quick Action / workflow).
  - Runs: ffmpeg -i <file>  (captures stderr for metadata lines).
  - Parses FFmpeg output lines to extract:
      • Codec Type
      • Avg. FPS
      • Video Bitrate
      • Video Resolution
  - Presents results in a simple dialog.

  Requirements:
  - FFmpeg must be installed and accessible.
  - The script currently references a fixed FFmpeg path:
        /usr/local/Cellar/ffmpeg/5.1.2_5/bin/ffmpeg
    Adjust this to match your system (e.g., /opt/homebrew/bin/ffmpeg on Apple Silicon
    Homebrew, or use a wrapper like `/usr/bin/env ffmpeg` plus PATH setup).

  Notes:
  - FFmpeg writes stream info to stderr; the script captures both stdout/stderr.
  - Output formats and field labels can vary by FFmpeg version; parsing may require
    tweaks if fields aren’t found.
  - Consider using `ffprobe` for structured JSON output to simplify parsing:
        ffprobe -v error -show_streams -of json <file>
  - If multiple streams exist, you may want to target the first video stream only.

  Example:
  Input:  /Users/john/Videos/sample.mov
  Output Dialog:
      Codec Type: h264 (High)
      Avg. FPS:   29.97
      Video Data Rate: 6.2 Mbps
      Video Resolution: 3840x2160
*)

on run {input, parameters}
	
	tell application "Finder"
		set theFile to item 1 of input
		get info for theFile
	end tell
	
	-- Get video info using ffmpeg
	set ffmpegPath to "/usr/local/Cellar/ffmpeg/5.1.2_5/bin/ffmpeg" -- Replace with your ffmpeg installation path
	set ffmpegOutput to do shell script ffmpegPath & " -i " & quoted form of POSIX path of theFile & " 2>&1"
	
	-- Parse ffmpeg output to get desired data
	set codecType to ""
	set avgFPS to ""
	set videoBitrate to ""
	set videoResolution to ""
	
	set ffmpegLines to paragraphs of ffmpegOutput
	repeat with aLine in ffmpegLines
		if it contains "Stream #" then
			set codecType to {text items of aLine, after "Codec:"} as string
		else if it contains "Avg. FPS:" then
			set avgFPS to {text items of aLine, after "Avg. FPS:"} as string
		else if it contains "bitrate:" then
			set videoBitrate to {text items of aLine, after "bitrate:"} as string
		else if it contains "Stream size:" then
			set videoResolution to {text items of aLine, after "Stream size:"} as string
		end if
	end repeat
	
	-- Format and display results in a text window
	set resultsText to "Codec Type: " & codecType & return & return
	set resultsText to resultsText & "Avg. FPS: " & avgFPS & return & return
	
	if videoBitrate contains "kbps" then
		set resultsText to resultsText & "Video Data Rate: " & videoBitrate & return & return
	else
		set AppleScript's text item delimiters to ":"
		set videoBitrateNumber to second text item of videoBitrate
		set videoBitrateMBps to (round (videoBitrateNumber / 1024) rounding as taught in school) as string
		set resultsText to resultsText & "Video Data Rate: " & videoBitrateMBps & " Mbps" & return & return
		set AppleScript's text item delimiters to ""
	end if
	
	set resultsText to resultsText & "Video Resolution: " & videoResolution
	
	display dialog resultsText buttons {"OK"} default button 1
	
end run