#!/usr/bin/env bash
#
# tapecap-gui.command — a native macOS front-end for tapecap
#
# This is ONLY a GUI wrapper. It reimplements none of tapecap's logic: it
# collects your choices with native dialogs (AppleScript / osascript) and then
# calls the real `tapecap` binary (https://github.com/xingrz/tapecap) with the
# matching flags. All the real work — listing, capturing, positioning — is done
# by tapecap exactly as on the command line, and its full output streams into
# this Terminal window.
#
# Double-click this file in Finder (it opens in Terminal). Requires macOS and a
# built `tapecap` binary. SPDX-License-Identifier: MIT
set -uo pipefail

TITLE="TapeCap"
HERE="$(cd "$(dirname "$0")" && pwd)"

# ----------------------------------------------------------------------------
# locate the tapecap binary: bundled/next-to-us, then PATH, then usual spots
# ----------------------------------------------------------------------------
find_tapecap() {
  local p
  # a tapecap binary shipped alongside this wrapper (e.g. in the .app Resources)
  [ -x "$HERE/tapecap" ] && { echo "$HERE/tapecap"; return; }
  p="$(command -v tapecap 2>/dev/null || true)"
  [ -n "$p" ] && { echo "$p"; return; }
  for d in /usr/local/bin /opt/homebrew/bin "$HOME/bin" "$HOME/.local/bin"; do
    [ -x "$d/tapecap" ] && { echo "$d/tapecap"; return; }
  done
  osa <<'AS' 2>/dev/null || echo ""
try
  set f to choose file with prompt "Locate the tapecap binary (from xingrz/tapecap)"
  return POSIX path of f
on error
  return ""
end try
AS
}

# ----------------------------------------------------------------------------
# osascript dialog helpers (dynamic text passed as argv to avoid quoting hell)
# ----------------------------------------------------------------------------
osa() { osascript "$@"; }

msg() { # msg <text> [icon: note|caution|stop]
  local icon="${2:-note}"
  osa - "$1" "$TITLE" "$icon" <<'AS' >/dev/null 2>&1 || true
on run argv
  set t to item 1 of argv
  set ttl to item 2 of argv
  set ic to item 3 of argv
  if ic is "stop" then
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon stop
  else if ic is "caution" then
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon caution
  else
    display dialog t buttons {"OK"} default button "OK" with title ttl with icon note
  end if
end run
AS
}

ask() { # ask <prompt> <default> -> text or "CANCEL"
  osa - "$1" "$2" "$TITLE" <<'AS' 2>/dev/null || echo CANCEL
on run argv
  try
    set r to display dialog (item 1 of argv) default answer (item 2 of argv) with title (item 3 of argv) buttons {"Cancel", "OK"} default button "OK"
    return text returned of r
  on error
    return "CANCEL"
  end try
end run
AS
}

pick_from() { # pick_from <prompt> item...  -> chosen item or "CANCEL"
  osa - "$@" <<'AS' 2>/dev/null || echo CANCEL
on run argv
  set thePrompt to item 1 of argv
  set theItems to rest of argv
  if theItems is {} then return "CANCEL"
  set c to choose from list theItems with prompt thePrompt OK button name "OK" cancel button name "Cancel"
  if c is false then return "CANCEL"
  return item 1 of c
end run
AS
}

pick_save() { # pick_save <defaultName> -> POSIX path or "CANCEL"
  osa - "$1" <<'AS' 2>/dev/null || echo CANCEL
on run argv
  try
    set f to choose file name with prompt "Save captured video as:" default name (item 1 of argv)
    return POSIX path of f
  on error
    return "CANCEL"
  end try
end run
AS
}

# ----------------------------------------------------------------------------
# sanity
# ----------------------------------------------------------------------------
if ! command -v osascript >/dev/null 2>&1; then
  echo "This GUI wrapper requires macOS (osascript)." >&2
  exit 1
fi

TAPECAP="$(find_tapecap)"
if [ -z "$TAPECAP" ]; then
  msg "Could not find the tapecap binary. Build it from github.com/xingrz/tapecap (git clone && make), then try again." stop
  exit 1
fi

run_tc() { "$TAPECAP" "$@"; }

GUID=""       # selected device GUID (empty = tapecap's default)
GUID_LABEL="default"

clear 2>/dev/null || true
echo "== $TITLE GUI — the log below is produced by tapecap (unchanged) =="
echo "tapecap: $TAPECAP"
echo

# ----------------------------------------------------------------------------
# main menu loop
# ----------------------------------------------------------------------------
while true; do
  CHOICE="$(pick_from "Device: $GUID_LABEL" \
    "Select device" "Deck info" "Capture" "Cue (position)" "Jog (position)" "Wind (position)" "Quit")"
  case "$CHOICE" in
    "Select device")
      echo "── Scanning devices (tapecap list) ──"
      OUT="$(run_tc list 2>&1)"; echo "$OUT"
      LINES=()
      while IFS= read -r line; do
        printf '%s' "$line" | grep -Eq '0x[0-9A-Fa-f]{6,16}' && LINES+=("$line")
      done <<< "$OUT"
      if [ "${#LINES[@]}" -eq 0 ]; then
        msg "No FireWire devices found. See the Terminal window for the raw list." caution
      else
        SEL="$(pick_from "Select a FireWire device:" "${LINES[@]}")"
        if [ "$SEL" != "CANCEL" ]; then
          GUID="$(printf '%s' "$SEL" | grep -oE '0x[0-9A-Fa-f]{6,16}' | head -n1)"
          GUID_LABEL="$SEL"
          echo "✓ Selected: $GUID_LABEL"
        fi
      fi
      ;;
    "Deck info")
      echo "── Deck info ──"
      if [ -n "$GUID" ]; then run_tc info --guid "$GUID" --json; else run_tc info --json; fi
      ;;
    "Capture")
      FMT="$(pick_from "Capture format:" "auto" "dv" "hdv")"
      [ "$FMT" = "CANCEL" ] && continue
      DEF="capture.dv"; [ "$FMT" = "hdv" ] && DEF="capture.m2t"
      OUTF="$(pick_save "$DEF")"; [ "$OUTF" = "CANCEL" ] && continue
      DUR="$(ask "Duration in seconds (blank = until end / EOT):" "")"
      [ "$DUR" = "CANCEL" ] && continue
      ARGS=(capture)
      [ -n "$GUID" ] && ARGS+=(--guid "$GUID")
      [ "$FMT" != "auto" ] && ARGS+=(--format "$FMT")
      [ -n "$DUR" ] && ARGS+=(--duration "$DUR")
      ARGS+=(--verbose "$OUTF")
      echo "── Capturing → $OUTF  ($FMT) ──"
      echo "» Recording. Press Ctrl-C in this window to stop and finalize."
      if run_tc "${ARGS[@]}"; then
        echo "✓ Capture saved: $OUTF"
        msg "Capture finished:

$OUTF" note
      else
        echo "✗ Capture ended with an error. See the log above."
        msg "Capture ended with an error — see the Terminal window." caution
      fi
      ;;
    "Cue (position)")
      TC="$(ask "Cue to timecode (HH:MM:SS, MM:SS, or seconds):" "00:30:00")"
      [ "$TC" = "CANCEL" ] && continue
      echo "── Cue → $TC ──"
      if [ -n "$GUID" ]; then run_tc cue --guid "$GUID" "$TC"; else run_tc cue "$TC"; fi
      ;;
    "Jog (position)")
      DIR="$(pick_from "Jog direction:" "forward" "back")"
      [ "$DIR" = "CANCEL" ] && continue
      SEC="$(ask "Jog how many seconds?" "5")"
      [ "$SEC" = "CANCEL" ] && continue
      echo "── Jog $DIR ${SEC}s ──"
      if [ -n "$GUID" ]; then run_tc jog --guid "$GUID" "$DIR" "$SEC"; else run_tc jog "$DIR" "$SEC"; fi
      ;;
    "Wind (position)")
      TGT="$(pick_from "Wind to:" "start" "end")"
      [ "$TGT" = "CANCEL" ] && continue
      echo "── Wind to $TGT ──"
      if [ -n "$GUID" ]; then run_tc wind --guid "$GUID" "$TGT"; else run_tc wind "$TGT"; fi
      ;;
    "Quit"|"CANCEL"|"")
      break
      ;;
  esac
  echo
done
echo "Goodbye."
