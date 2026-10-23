-- Before sharing the main display: move every visible window on it, except terminals and editors,
-- to the other display and fill it (through each app's Window menu "Move to ..." and "Fill").
use framework "AppKit"
use scripting additions

set skipApps to {"Ghostty", "Terminal", "WezTerm", "Kitty", "Bruno", "Code", "Cursor"}

set mainFrame to ((current application's NSScreen's screens())'s objectAtIndex:0)'s frame()
set {mainW, mainH} to item 2 of mainFrame

tell application "System Events"
	repeat with proc in (every process whose visible is true)
		if name of proc is not in skipApps then
			-- raising a window reorders the window list, so look for the next one from scratch after each move;
			-- moved windows leave the main display, so this stops after at most one pass per window
			repeat (count of windows of proc) times
				set i to my firstWindowOnMain(proc, mainW, mainH)
				if i is 0 then exit repeat
				try
					set frontmost of proc to true
					perform action "AXRaise" of window i of proc
					tell menu "Window" of menu bar 1 of proc
						click (first menu item whose name begins with "Move to")
						click menu item "Fill"
					end tell
				on error -- app without a Window menu, or without these items
					exit repeat
				end try
			end repeat
		end if
	end repeat
end tell

-- Index of proc's first window whose top-left corner is on the main display, 0 if none.
-- Fetches every position in one Apple Event instead of one per window.
on firstWindowOnMain(proc, mainW, mainH)
	tell application "System Events"
		try
			set positions to position of every window of proc
		on error
			return 0
		end try
	end tell
	repeat with i from 1 to count of positions
		set p to item i of positions
		if class of p is list then
			set {wx, wy} to p
			if wx >= 0 and wx < mainW and wy >= 0 and wy < mainH then return i
		end if
	end repeat
	return 0
end firstWindowOnMain
