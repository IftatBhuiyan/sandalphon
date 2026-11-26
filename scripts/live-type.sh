#!/bin/bash
# Types TEXT into the frontmost app one key at a time (like a fast typist), then prints what the field
# contains afterwards. Usage: live-type.sh "text" [delay_seconds]
TEXT="$1"; DELAY="${2:-0.035}"
osascript - "$TEXT" "$DELAY" <<'OSA'
on run argv
  set t to item 1 of argv
  set d to (item 2 of argv) as real
  tell application "System Events"
    repeat with c in characters of t
      keystroke c
      delay d
    end repeat
  end tell
end run
OSA
