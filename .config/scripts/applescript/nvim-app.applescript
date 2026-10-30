-- Source for ~/Applications/Nvim.app (built by setup.sh): lets Finder open files in nvim inside a new Ghostty window.
-- setup.sh fills in nvim's full path below, since apps don't get the shell's PATH.
property nvimCmd : "open -na Ghostty --args -e @NVIM@"

on open theFiles
	set args to ""
	repeat with f in theFiles
		set args to args & " " & quoted form of POSIX path of f
	end repeat
	do shell script nvimCmd & args
end open

on run
	do shell script nvimCmd
end run
