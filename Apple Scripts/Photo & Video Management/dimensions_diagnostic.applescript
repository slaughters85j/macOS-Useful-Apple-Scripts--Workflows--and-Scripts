(*
  Video Dimension Reporter (macOS AppleScript)
  -------------------------------------------------------------------------
  Description:
  Prompts the user to select a folder containing video files, then scans all
  supported video formats within that folder to extract their resolution
  (width and height in pixels). The results are displayed in a summary dialog.

  Behavior:
  - Prompts for a folder containing video files.
  - Uses macOS Spotlight metadata (mdls) to retrieve dimensions.
  - Supports a variety of common video formats (mp4, mov, avi, mkv, m4v, flv, wmv).
  - Displays the gathered information in a simple dialog for review.

  Requirements:
  - macOS must have Spotlight metadata indexing enabled.
  - The mdls command must be available (it is by default on macOS).
  - Only files in the top level of the selected folder are processed.

  Notes:
  - The script ignores subfolders.
  - You may adjust the `supportedFormats` property to match your preferred
    list of video extensions.
  - Dimensions are reported as stored in the file’s metadata and may differ
    slightly from the actual encoded frame size if metadata is stale.

  Example:
  Selecting a folder containing `clip1.mp4` and `clip2.mov` will produce:
      File: ./clip1.mp4
      Width: 1920
      Height: 1080

      File: ./clip2.mov
      Width: 3840
      Height: 2160
*)

-- Configuration
property supportedFormats : {"mp4", "mov", "avi", "mkv", "m4v", "flv", "wmv"}

-- Ask user to select the folder
set theFolder to choose folder with prompt "Select the folder containing videos to organize:"
set folderPath to POSIX path of theFolder

-- Get video files using shell
set videoList to do shell script "cd " & quoted form of folderPath & " && find . -maxdepth 1 -type f \\( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.m4v' -o -iname '*.flv' -o -iname '*.wmv' \\)"

-- Process each video
set videoFiles to paragraphs of videoList
set debugInfo to ""

repeat with videoFile in videoFiles
	if videoFile is not "" then
		set videoPath to folderPath & text 3 thru -1 of videoFile -- Remove "./" prefix
		
		-- Get dimensions
		set width to do shell script "mdls -name kMDItemPixelWidth -raw " & quoted form of videoPath
		set height to do shell script "mdls -name kMDItemPixelHeight -raw " & quoted form of videoPath
		
		set debugInfo to debugInfo & "File: " & videoFile & return & "Width: " & width & return & "Height: " & height & return & return
	end if
end repeat

display dialog debugInfo buttons {"OK"} default button "OK"