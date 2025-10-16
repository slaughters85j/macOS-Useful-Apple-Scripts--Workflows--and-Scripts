(*
  VOC XML Annotation Generator (macOS AppleScript)
  -------------------------------------------------------------------------
  Description:
  Automates the generation of Pascal VOC-style XML annotation files for a folder
  of images. Prompts the user to select an image folder, extracts each imageÕs
  dimensions, and creates a matching XML annotation file for each image in a
  sibling "Annotations" directory.

  Behavior:
  - Prompts for a folder containing images.
  - Creates an "Annotations" directory one level above the selected folder.
  - Extracts image dimensions (width and height) using macOS `sips`.
  - Generates VOC-format XML files containing filename, folder, dimensions,
    and a placeholder bounding box covering the entire image.
  - Infers a Òperson nameÓ or label from the first two tokens of the filename.
  - Displays a completion dialog summarizing success and error counts.

  Requirements:
  - macOS must have the `sips` utility (included by default).
  - Script must have permission to run shell commands.
  - Filenames should include label identifiers separated by spaces or underscores.
  - Supported formats include png, jpg, jpeg, tiff, and gif.

  Notes:
  - XML files are saved under ../Annotations relative to the selected folder.
  - Default image depth is set by `defaultDepth` (3 = RGB).
  - If dimensions cannot be read, the file is skipped and logged as an error.
  - Adjust the person-name extraction logic to match your naming convention.

  Example:
  Folder: /Users/john/TrainingImages/Set1
      Image:  Alice_Smith_01.jpg
      Output: ../Annotations/Alice_Smith_01.xml
      Folder: ../Annotations/

  Example XML snippet:
      <annotation>
          <folder>TrainingImages</folder>
          <filename>Alice_Smith_01.jpg</filename>
          <size>
              <width>1920</width>
              <height>1080</height>
              <depth>3</depth>
          </size>
          <object>
              <name>Alice_Smith</name>
              <bndbox>
                  <xmin>0</xmin><ymin>0</ymin><xmax>1920</xmax><ymax>1080</ymax>
              </bndbox>
          </object>
      </annotation>
*)

-- Configuration
property supportedFormats : {"png", "jpg", "jpeg", "tiff", "gif"}
property defaultDepth : 3

-- Ask user to select the folder containing images
set theFolder to choose folder with prompt "Select the folder containing the images for annotation:"

-- Create Annotations directory one level up
set parentFolder to text 1 thru -((length of last text item of (POSIX path of theFolder)) + 1) of (POSIX path of theFolder)
set annotationFolder to parentFolder & "Annotations/"

try
	do shell script "mkdir -p " & quoted form of annotationFolder
on error errMsg
	display dialog "Error creating Annotations folder: " & errMsg buttons {"OK"} default button "OK"
	return
end try

-- Get image files
tell application "Finder"
	set imageFiles to files of folder theFolder whose name extension is in supportedFormats
end tell

on extractPersonName(fileName)
	set AppleScript's text item delimiters to " "
	set nameComponents to text items of fileName
	set AppleScript's text item delimiters to "_"
	return items 1 through 2 of nameComponents as string
end extractPersonName

on generateVOCXML(imageName, width, height, depth, folderPath, personName)
	return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<annotation>
    <folder>" & folderPath & "</folder>
    <filename>" & imageName & "</filename>
    <size>
        <width>" & width & "</width>
        <height>" & height & "</height>
        <depth>" & depth & "</depth>
    </size>
    <object>
        <name>" & personName & "</name>
        <pose>Unspecified</pose>
        <truncated>0</truncated>
        <difficult>0</difficult>
        <bndbox>
            <xmin>0</xmin>
            <ymin>0</ymin>
            <xmax>" & width & "</xmax>
            <ymax>" & height & "</ymax>
        </bndbox>
    </object>
</annotation>"
end generateVOCXML

-- Process images
set successCount to 0
set errorCount to 0

repeat with anImage in imageFiles
	tell application "Finder"
		set imageName to name of anImage
		set imagePath to POSIX path of (anImage as alias)
		set personName to my extractPersonName(imageName)
	end tell
	
	try
		-- Get image dimensions
		set dimensionCmd to "sips -g pixelWidth -g pixelHeight \"" & imagePath & "\" 2>/dev/null"
		set dimensions to paragraphs of (do shell script dimensionCmd)
		
		set width to missing value
		set height to missing value
		
		repeat with dimLine in dimensions
			if dimLine contains "pixelWidth" then
				set width to last word of dimLine as integer
			else if dimLine contains "pixelHeight" then
				set height to last word of dimLine as integer
			end if
		end repeat
		
		if width is missing value or height is missing value then error "Invalid dimensions"
		
		-- Generate and write XML
		set xmlContent to generateVOCXML(imageName, width, height, defaultDepth, POSIX path of theFolder, personName)
		set xmlFileName to text 1 thru ((offset of "." in imageName) - 1) of imageName & ".xml"
		set xmlPath to POSIX path of annotationFolder & xmlFileName
		
		do shell script "echo " & quoted form of xmlContent & " > " & quoted form of xmlPath
		set successCount to successCount + 1
		
	on error errMsg
		set errorCount to errorCount + 1
		log "Error processing " & imageName & ": " & errMsg
	end try
end repeat

display dialog "Processing complete:" & return & Â
	successCount & " files processed successfully" & return & Â
	errorCount & " files had errors" buttons {"OK"} default button "OK"