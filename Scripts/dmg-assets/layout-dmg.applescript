-- layout-dmg.applescript — arrange the mounted DMG's Finder window: icon view,
-- branded background, app icon on the left, Applications on the right.
-- Usage: osascript layout-dmg.applescript <volume-name>
-- The volume must be mounted under /Volumes (Finder only scripts volumes there).
-- Requires Automation permission for Finder; release-dmg.sh treats failure here
-- as non-fatal and falls back to a plain window.

on run argv
	set volName to item 1 of argv
	tell application "Finder"
		tell disk volName
			open
			delay 1
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set the bounds of container window to {200, 120, 800, 520}
			set theViewOptions to the icon view options of container window
			set arrangement of theViewOptions to not arranged
			set icon size of theViewOptions to 100
			set text size of theViewOptions to 12
			set background picture of theViewOptions to file ".background:dmg-background.png"
			set position of item "Yappy.app" of container window to {150, 190}
			set position of item "Applications" of container window to {450, 190}
			update without registering applications
			delay 1
			close
		end tell
	end tell
end run
