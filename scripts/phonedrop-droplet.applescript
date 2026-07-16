-- PhoneDrop Dock droplet
-- Thin shim: receives dropped files and delegates all logic to phonedrop.sh.
-- Multi-target routing prefers per-phone folders (~/PhoneDrop/<name>/) via launchd;
-- this droplet still pushes to the default/legacy Android target (or sole target).
-- Compiled via: osacompile -o ~/Applications/PhoneDrop.app phonedrop-droplet.applescript

on open theFiles
    -- Build a space-separated, shell-quoted list of POSIX paths
    set quotedPaths to ""
    repeat with aFile in theFiles
        set posixPath to POSIX path of aFile
        -- Shell-quote each path: wrap in single quotes, escape internal single quotes
        set escapedPath to do shell script "printf '%s' " & quoted form of posixPath & " | sed \"s/'/'\\''/g\""
        set quotedPaths to quotedPaths & " '" & escapedPath & "'"
    end repeat

    -- Path to the installed logic script (stable; does not depend on source location)
    set logicScript to (POSIX path of (path to library folder from user domain)) & "Application Support/PhoneDrop/phonedrop.sh"

    -- Optional: set PHONEDROP_TARGET in the environment before launch to pin a named phone.
    -- Invoke push verb with all quoted paths
    try
        do shell script "exec " & quoted form of logicScript & " push" & quotedPaths
    on error errMsg number errNum
        display notification "PhoneDrop failed: " & errMsg with title "PhoneDrop Error"
    end try
end open

on run
    display dialog "PhoneDrop is a Dock droplet. Drag photos onto its icon to send them to your default phone target. Prefer per-phone folders under ~/PhoneDrop/ for multi-target routing." buttons {"OK"} default button "OK"
end run
