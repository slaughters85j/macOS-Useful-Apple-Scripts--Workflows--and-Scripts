(*
  Video Batch Renamer with Folder Prefix (macOS AppleScript)
  -------------------------------------------------------------------------
  Description:
  Prompts the user to select a folder containing video files, then automatically
  renames each file by prefixing it with the folder’s name and a zero-padded
  sequence number. Ideal for preparing sequentially named media for upload,
  editing, or archival purposes.

  Behavior:
  - Prompts for a folder containing video files.
  - Detects video formats listed in `supportedFormats`.
  - Extracts the folder’s name to use as the filename prefix.
  - Sequentially renames each file as:
        <FolderName>_000001.<ext>
        <FolderName>_000002.<ext>
        ...
  - Displays a completion dialog summarizing the operation.

  Requirements:
  - The script must be granted access to Finder for file renaming.
  - Supported file formats include mp4, mov, avi, mkv, m4v, flv, and wmv.

  Notes:
  - Files are processed in the order returned by Finder (not guaranteed sorted).
  - Padding width (six digits) can be adjusted by changing `"000000" & i`.
  - Renaming is destructive; filenames are replaced in place.
  - Does not recurse into subfolders—only processes the selected directory.

  Example:
  Folder:  /Users/john/Videos/TripFootage
      TripFootage_000001.mp4
      TripFootage_000002.mp4
      TripFootage_000003.mov
*)

-- Configuration
property supportedFormats : {"mp4", "mov", "avi", "mkv", "m4v", "flv", "wmv"}

-- Ask user to select the folder
set theFolder to choose folder with prompt "Select the folder containing the videos to rename:"

-- Get folder name
tell application "Finder"
	set folderName to name of folder theFolder
	set videoFiles to files of folder theFolder whose name extension is in supportedFormats
end tell

-- Loop through videos and rename with folder prefix
repeat with i from 1 to count of videoFiles
	set paddedIndex to text -6 thru -1 of ("000000" & i)
	set currentVideo to item i of videoFiles
	
	tell application "Finder"
		set fileExt to name extension of currentVideo
		set newName to folderName & "_" & paddedIndex & "." & fileExt
		set name of currentVideo to newName
	end tell
end repeat

display dialog "Videos renamed with folder prefix: " & folderName buttons {"OK"} default button "OK"