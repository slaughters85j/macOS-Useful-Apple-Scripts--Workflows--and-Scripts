(*
  Audio File Converter for macOS Automator Quick Action
  - Uses custom ffmpeg path with fallback to miniforge3 location
*)

property FFMPEG_BIN : ""

on run {input, parameters}
	-- Set ffmpeg path (custom or default miniforge3 location)
	if FFMPEG_BIN is not "" then
		set ffmpegPath to FFMPEG_BIN
	else
		set ffmpegPath to "/Users/system-backup/miniforge3/bin/ffmpeg"
	end if
	
	-- Verify ffmpeg exists at specified path
	try
		do shell script "test -x " & quoted form of ffmpegPath
	on error
		display alert "ffmpeg not found" message "ffmpeg not found at: " & ffmpegPath & return & return & "Please update FFMPEG_BIN property with correct path." as critical
		error number -128
	end try
	
	set theFiles to input
	if (count of theFiles) is 0 then
		display alert "No Files Selected" message "Please select one or more audio files to convert." as warning
		error number -128
	end if
	
	-- Select target format
	set formatOptions to {".mp3", ".wav", ".m4a", ".avi"}
	set selectedFormats to choose from list formatOptions with title "Target Format" with prompt "Choose target audio format:" default items {".mp3"} OK button name "Select" cancel button name "Cancel" without multiple selections allowed
	if selectedFormats is false then error number -128
	set targetFormat to item 1 of selectedFormats
	
	-- Select sample rate
	set rateOptions to {"Use Original", "48000", "44100", "22050", "16000", "11025", "8000"}
	set selectedRates to choose from list rateOptions with title "Sample Rate" with prompt "Choose sample rate (Hz):" default items {"Use Original"} OK button name "Select" cancel button name "Cancel" without multiple selections allowed
	if selectedRates is false then error number -128
	set sampleRate to item 1 of selectedRates
	
	-- Check for macOS hardware acceleration
	set useHardware to false
	try
		do shell script ffmpegPath & " -encoders 2>/dev/null | grep -q 'aac_at'"
		set useHardware to true
	end try
	
	-- Initialize counters
	set successCount to 0
	set failCount to 0
	set failNames to {}
	
	-- Process each file
	repeat with aFile in theFiles
		set filePath to POSIX path of aFile
		set fileInfo to getFileInfo(filePath)
		set baseName to |baseName| of fileInfo
		set containerDir to |containerDir| of fileInfo
		
		-- Construct output path
		set outputPath to containerDir & "/" & baseName & targetFormat
		set finalOutputPath to outputPath
		
		-- Handle duplicate names
		tell application "System Events"
			set counter to 1
			repeat while (exists file finalOutputPath)
				set finalOutputPath to containerDir & "/" & baseName & "_" & counter & targetFormat
				set counter to counter + 1
			end repeat
		end tell
		
		-- Build ffmpeg command with full path
		set ffmpegCmd to ffmpegPath & " -i " & quoted form of filePath
		
		-- Add sample rate if specified
		if sampleRate is not "Use Original" then
			set ffmpegCmd to ffmpegCmd & " -ar " & sampleRate
		end if
		
		-- Format-specific settings
		if targetFormat is ".mp3" then
			set ffmpegCmd to ffmpegCmd & " -c:a libmp3lame -q:a 2"
		else if targetFormat is ".wav" then
			set ffmpegCmd to ffmpegCmd & " -c:a pcm_s16le"
		else if targetFormat is ".m4a" then
			if useHardware then
				set ffmpegCmd to ffmpegCmd & " -c:a aac_at -b:a 256k"
			else
				set ffmpegCmd to ffmpegCmd & " -c:a aac -b:a 256k"
			end if
		else if targetFormat is ".avi" then
			set ffmpegCmd to ffmpegCmd & " -c:a libmp3lame -q:a 2"
		end if
		
		set ffmpegCmd to ffmpegCmd & " " & quoted form of finalOutputPath
		
		-- Execute conversion
		try
			do shell script ffmpegCmd
			set successCount to successCount + 1
		on error errMsg
			set failCount to failCount + 1
			set end of failNames to baseName
		end try
	end repeat
	
	-- Show completion summary
	set summary to "Successfully converted: " & successCount & " file(s)"
	if failCount > 0 then
		set summary to summary & return & "Failed: " & failCount & " file(s)" & return & return & "Failed files:" & return & (failNames as string)
		display alert "Conversion Complete" message summary as warning
	else
		display notification summary with title "Batch Conversion Complete"
	end if
end run

on getFileInfo(filePath)
	set AppleScript's text item delimiters to "/"
	set pathComponents to text items of filePath
	set fileName to last item of pathComponents
	set containerDir to (text items 1 thru -2 of pathComponents) as string
	set AppleScript's text item delimiters to "."
	if fileName contains "." then
		set baseName to (text items 1 thru -2 of fileName) as string
	else
		set baseName to fileName
	end if
	set AppleScript's text item delimiters to ""
	return {|baseName|:baseName, |containerDir|:containerDir}
end getFileInfo