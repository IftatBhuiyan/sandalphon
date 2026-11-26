#!/bin/bash
# live-case.sh APP FILE LABEL: opens FILE in APP, types a test passage, summons suggestions, screenshots,
# and prints the resulting text. Leaves the page open.
APP="$1"; FILE="$2"; LABEL="$3"; OUT="$4"
HERE="$(dirname "$0")"
open -a "$APP" "$FILE"; sleep 3.5
: > "$TMPDIR/sandalphon-debug.log"
"$HERE/live-type.sh" "teh fox jumsp over, i dont knwo waht you mean. thankyou for the mesage, see you tomor" 0.03
sleep 0.3
osascript -e 'tell application "System Events" to key code 53 using option down'; sleep 0.8
screencapture -x "$OUT/$LABEL.png"
osascript -e 'tell application "System Events" to key code 48'; sleep 0.3
osascript -e 'tell application "System Events" to keystroke "a" using command down' -e 'delay 0.25' -e 'tell application "System Events" to keystroke "c" using command down'; sleep 0.3
echo "$LABEL: [$(pbpaste)]"
echo "  front: $(osascript -e 'tell application "System Events" to return name of first process whose frontmost is true')  mismatches: $(grep -c mismatch "$TMPDIR/sandalphon-debug.log")  last: $(grep verify "$TMPDIR/sandalphon-debug.log" | tail -1 | cut -c1-150)"
