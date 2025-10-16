(*
  Image Batch Renamer with Folder Prefix (macOS AppleScript)
  -------------------------------------------------------------------------
  Description:
  Prompts the user to select a folder containing image files, then sequentially
  renames each file by prefixing it with the folder’s name and a zero-padded
  index number. Designed for preparing image datasets or photo sets that require
  consistent naming conventions.

  Behavior:
  - Prompts the user to select a folder containing images.
  - Retrieves the folder’s name to use as the prefix for each image.
  - Renames files sequentially as:
        <FolderName>_000001.<ext>
        <FolderName>_000002.<ext>
        ...
  - Displays a completion dialog showing the processed folder name.

  Requirements:
  - The script must have access to Finder for file renaming operations.
  - Supported formats include png, jpg, jpeg, tiff, and gif.
  - macOS automation permissions must allow Finder scripting.

  Notes:
  - The renaming order follows Finder’s returned file list (not sorted by date).
  - Padding width (six digits) can be modified by editing `"000000" & i`.
  - Renaming is destructive—original filenames are replaced in place.
  - Subfolders are ignored; only files in the selected directory are processed.

  Example:
  Folder:  /Users/john/Photos/Vacation2025
      Vacation2025_000001.jpg
      Vacation2025_000002.png
      Vacation2025_000003.jpeg
*)

-- Configuration
property supportedFormats : {"png", "jpg", "jpeg", "tiff", "gif"}

-- Ask user to select the folder
set theFolder to choose folder with prompt "Select the folder containing the images to rename:"

-- Get folder name
tell application "Finder"
	set folderName to name of folder theFolder
	set imageFiles to files of folder theFolder whose name extension is in supportedFormats
end tell

-- Loop through images and rename with folder prefix
repeat with i from 1 to count of imageFiles
	set paddedIndex to text -6 thru -1 of ("000000" & i)
	set currentImage to item i of imageFiles
	
	tell application "Finder"
		set fileExt to name extension of currentImage
		set newName to folderName & "_" & paddedIndex & "." & fileExt
		set name of currentImage to newName
	end tell
end repeat

display dialog "Images renamed with folder prefix: " & folderName buttons {"OK"} default button "OK"