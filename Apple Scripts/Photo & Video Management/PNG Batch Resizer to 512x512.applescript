(*
  PNG Batch Resizer to 512x512 (macOS AppleScript)
  -------------------------------------------------------------------------
  Description:
  Resizes all PNG images in a specified directory to 512x512 pixels using the
  built-in macOS `sips` command-line utility. This is ideal for quickly
  preparing image sets for training data, thumbnails, or uniform publishing.

  Behavior:
  - Defines the target directory containing PNG files.
  - Executes a shell command to batch-resize all *.png images to 512x512.
  - Displays a success dialog upon completion, or an error dialog if any
    operation fails.

  Requirements:
  - The `sips` utility must be available (included by default on macOS).
  - The input directory path must exist and contain `.png` files.
  - The script must have permission to execute shell commands.

  Notes:
  - Overwrites images in place; original dimensions are lost.
  - To resize images proportionally, use `sips --resampleWidth` or
    `--resampleHeight` instead of fixed dimensions.
  - You may modify the pixel size (512x512) or add other image formats by
    editing the shell command.

  Example:
  Input Directory:
      /Users/john/Pictures/Convert_Size/
  Command Executed:
      cd "/Users/john/Pictures/Convert_Size" && for file in *.png; do sips -z 512 512 "$file"; done
  Output:
      All PNG images resized to 512x512 successfully!
*)

-- Define the corrected directory containing the PNG images
set inputDirectory to "/Users/system-backup/Pictures/COnvert_Size"

-- Resize PNG images
try
	do shell script "cd " & quoted form of inputDirectory & " && for file in *.png; do sips -z 512 512 \"$file\"; done"
	display dialog "All PNG images resized to 512x512 successfully!" buttons {"OK"} default button "OK"
on error errMsg
	display dialog "An error occurred: " & errMsg buttons {"OK"} default button "OK"
end try