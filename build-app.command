#!/usr/bin/env bash
#
# build-app.command — assemble TapeCap.app (a proper macOS .app bundle)
#
# Run this ON THE MAC, in the folder that also holds TapeCap.swift,
# tapecap-gui.command, vendor/tapecap/ (the bundled tapecap source) and
# (optionally) AppIcon.png:
#
#     bash build-app.command            # compiles the vendored tapecap + the app
#     bash build-app.command --build    # force a fresh tapecap rebuild
#     bash build-app.command /path/to/tapecap   # bundle a prebuilt binary
#
# It produces TapeCap.app next to this script and reveals it in Finder. tapecap's
# source is vendored, so the normal build is fully offline and self-contained.
#
# It picks the best UI your Mac can compile, in this order:
#   1. Native Swift app (PREFERRED) — one window: device picker, format selector,
#      action buttons and a colored, streaming log. Needs Apple's Command Line
#      Tools (free):  xcode-select --install
#   2. Platypus "Text Window" app — log in-app, input via dialogs. Needs the
#      Platypus CLI (https://sveinbjorn.org/platypus → Install Command Line Tool).
#   3. Terminal-log fallback — a plain .app whose launcher shows the log in Terminal.
#
# This reimplements NONE of tapecap's logic — every build runs the real `tapecap`
# binary (github.com/xingrz/tapecap), found on your PATH at runtime.
#
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/TapeCap.app"
APPNAME="TapeCap"
VERSION="1.0.0"
BUNDLE_ID="com.kurdtnervanna.tapecap"

command -v osascript >/dev/null 2>&1 || { echo "This builder requires macOS."; exit 1; }
[ -f "$HERE/tapecap-gui.command" ] || { echo "Missing tapecap-gui.command next to build-app.command — keep them together."; exit 1; }

# ----------------------------------------------------------------------------
# icon: use AppIcon.icns if present, else build one from AppIcon.png
# ----------------------------------------------------------------------------
ICNS=""
if [ -f "$HERE/AppIcon.icns" ]; then
  ICNS="$HERE/AppIcon.icns"
elif [ -f "$HERE/AppIcon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  echo "Building AppIcon.icns from AppIcon.png…"
  ICONSET="$HERE/.AppIcon.iconset"; rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for pair in 16:16 16:32@2x 32:32 32:64@2x 128:128 128:256@2x 256:256 256:512@2x 512:512 512:1024@2x; do
    base="${pair%%:*}"; rest="${pair#*:}"; pxsz="${rest%%@*}"; sfx=""
    case "$rest" in *@2x) sfx="@2x";; esac
    sips -z "$pxsz" "$pxsz" "$HERE/AppIcon.png" --out "$ICONSET/icon_${base}x${base}${sfx}.png" >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$HERE/AppIcon.icns" >/dev/null 2>&1; then ICNS="$HERE/AppIcon.icns"; fi
  rm -rf "$ICONSET"
fi
[ -n "$ICNS" ] && echo "Icon: $ICNS" || echo "Icon: (generic — add AppIcon.png to brand it)"

# ----------------------------------------------------------------------------
# tapecap binary: bundle one so TapeCap.app is self-contained.
#   priority: ./tapecap next to this script → tapecap on PATH → build from source
# You can also pass an explicit path:  bash build-app.command /path/to/tapecap
# ----------------------------------------------------------------------------
confirm_yesno() {  # confirm_yesno <text> -> "Yes" or "No"
  osascript - "$1" <<'AS' 2>/dev/null || echo No
on run argv
  try
    display dialog (item 1 of argv) buttons {"No", "Yes"} default button "Yes" with title "TapeCap — build"
    return button returned of result
  on error
    return "No"
  end try
end run
AS
}

# tapecap's source is VENDORED in vendor/tapecap, so the normal build is fully
# offline and self-contained: compile it in place and bundle the binary. No
# separate download, no separate folder.
#
# make_tapecap builds a source tree (make → build/tapecap); needs only Xcode
# Command Line Tools (clang++) — no full Xcode, no swiftc, no network. Echoes the
# built binary path on success, nothing on failure.
VENDOR="$HERE/vendor/tapecap"

make_tapecap() {   # $1 = source dir; echoes built binary path or empty
  local SRC="$1" cand
  [ -d "$SRC" ] || { echo "! no tapecap source at $SRC" >&2; return 1; }
  command -v make >/dev/null 2>&1 || { echo "! make not found — run: xcode-select --install" >&2; return 1; }
  echo "» Building tapecap from $SRC (make)…" >&2
  if ( cd "$SRC" && make ) >&2; then
    for cand in "$SRC/build/tapecap" "$SRC/tapecap" "$SRC/bin/tapecap"; do
      [ -x "$cand" ] && { echo "$cand"; return 0; }
    done
    cand="$(find "$SRC" -type f -name tapecap -perm -111 2>/dev/null | head -n1 || true)"
    [ -n "$cand" ] && { echo "$cand"; return 0; }
    echo "! make finished but no tapecap binary was found." >&2; return 1
  fi
  echo "! tapecap build failed (needs macOS 11–15 with FireWire SDK headers)." >&2
  return 1
}

clone_and_make() {   # last resort: fetch upstream, then build
  command -v git >/dev/null 2>&1 || { echo "! git not found — run: xcode-select --install" >&2; return 1; }
  local SRC="$HERE/.tapecap-src"
  echo "» Cloning tapecap (git)…" >&2
  rm -rf "$SRC"
  git clone --depth 1 https://github.com/xingrz/tapecap "$SRC" >&2 || { echo "! git clone failed." >&2; return 1; }
  make_tapecap "$SRC"
}

# arg / mode: --build|-b forces a fresh build; a path uses that prebuilt binary.
FORCE_BUILD=0; EXPLICIT=""
case "${1:-}" in
  --build|-b) FORCE_BUILD=1 ;;
  "") ;;
  *) EXPLICIT="$1" ;;
esac

TCBIN=""
if [ "$FORCE_BUILD" = "1" ]; then
  if [ -d "$VENDOR" ]; then TCBIN="$(make_tapecap "$VENDOR" || true)"; else TCBIN="$(clone_and_make || true)"; fi
elif [ -n "$EXPLICIT" ] && [ -x "$EXPLICIT" ]; then
  TCBIN="$EXPLICIT"
elif [ -x "$HERE/tapecap" ]; then
  TCBIN="$HERE/tapecap"                       # a prebuilt binary dropped in
elif [ -d "$VENDOR" ]; then
  TCBIN="$(make_tapecap "$VENDOR" || true)"   # <-- integrated default: vendored source
elif command -v tapecap >/dev/null 2>&1; then
  TCBIN="$(command -v tapecap)"
elif [ "${BUILD_TAPECAP:-}" = "1" ] || [ "$(confirm_yesno "No bundled tapecap source or binary was found.

Download + build tapecap from source now? (git clone + make)")" = "Yes" ]; then
  TCBIN="$(clone_and_make || true)"
fi
if [ -n "$TCBIN" ]; then echo "tapecap to bundle: $TCBIN"; else echo "tapecap: (none bundled — app finds it on PATH at runtime)"; fi

# writes Contents/Info.plist for a hand-assembled bundle (Swift/Terminal builds)
write_plist() {
  cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${APPNAME}</string>
  <key>CFBundleDisplayName</key><string>${APPNAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleExecutable</key><string>${APPNAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>10.13</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST
}

# ----------------------------------------------------------------------------
# detect toolchains: swiftc (preferred, native one-window app) then Platypus
# ----------------------------------------------------------------------------
SWIFTC="$(command -v swiftc 2>/dev/null || true)"
[ -z "$SWIFTC" ] && SWIFTC="$(xcrun -f swiftc 2>/dev/null || true)"
PLAT="$(command -v platypus 2>/dev/null || true)"
for p in /usr/local/bin/platypus /opt/homebrew/bin/platypus "$HOME/bin/platypus"; do
  [ -z "$PLAT" ] && [ -x "$p" ] && PLAT="$p"
done
echo "swiftc:   ${SWIFTC:-NOT FOUND}"
echo "Platypus: ${PLAT:-NOT FOUND}"

rm -rf "$APP"

if [ -n "$SWIFTC" ] && [ -f "$HERE/TapeCap.swift" ]; then
  # ==========================================================================
  # PREFERRED: native single-window AppKit app (buttons + colored log)
  # ==========================================================================
  echo "Building native Swift app…"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  write_plist
  if "$SWIFTC" -O -o "$APP/Contents/MacOS/${APPNAME}" "$HERE/TapeCap.swift" -framework AppKit; then
    chmod +x "$APP/Contents/MacOS/${APPNAME}"
    [ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
    [ -n "$TCBIN" ] && { cp "$TCBIN" "$APP/Contents/Resources/tapecap"; chmod +x "$APP/Contents/Resources/tapecap"; }
    MODE_NOTE="native Swift app (one window, device picker, colored log)"
  else
    echo "swiftc failed — falling back."; rm -rf "$APP"; SWIFTC=""
  fi
fi

if [ ! -d "$APP" ] && [ -n "$PLAT" ]; then
  # ==========================================================================
  # FALLBACK 1: Platypus "Text Window" app (in-app log, input via dialogs)
  # ==========================================================================
  echo "Building with Platypus (in-app log window): $PLAT"
  args=( -y -a "$APPNAME" -o "Text Window" -p "/bin/bash"
         -V "$VERSION" -u "KurdtNervanna" -I "$BUNDLE_ID" )
  [ -n "$ICNS" ] && args+=( -i "$ICNS" )
  [ -n "$TCBIN" ] && args+=( -f "$TCBIN" )   # bundle tapecap into Resources
  "$PLAT" "${args[@]}" "$HERE/tapecap-gui.command" "$APP"
  MODE_NOTE="Platypus text-window (log in-app; input via dialogs)"
fi

if [ ! -d "$APP" ]; then
  # ==========================================================================
  # FALLBACK 2: plain .app whose launcher opens Terminal for the log
  # ==========================================================================
  echo "No swiftc or Platypus — building the Terminal-log fallback app."
  echo "  For the native one-window app, install Apple's Command Line Tools:"
  echo "     xcode-select --install"
  echo "  then re-run:  bash build-app.command"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  write_plist
  cat > "$APP/Contents/MacOS/${APPNAME}" <<'LAUNCH'
#!/bin/bash
RES="$(cd "$(dirname "$0")/../Resources" && pwd)"
GUI="$RES/tapecap-gui.command"
CMD="clear; exec '$GUI'"
/usr/bin/osascript >/dev/null 2>&1 <<AS
tell application "Terminal"
  activate
  do script "$CMD"
end tell
AS
LAUNCH
  chmod +x "$APP/Contents/MacOS/${APPNAME}"
  cp "$HERE/tapecap-gui.command" "$APP/Contents/Resources/tapecap-gui.command"
  chmod +x "$APP/Contents/Resources/tapecap-gui.command"
  [ -n "$ICNS" ] && cp "$ICNS" "$APP/Contents/Resources/AppIcon.icns"
  [ -n "$TCBIN" ] && { cp "$TCBIN" "$APP/Contents/Resources/tapecap"; chmod +x "$APP/Contents/Resources/tapecap"; }
  MODE_NOTE="Terminal log (install Xcode CLT for the native app)"
fi

# ----------------------------------------------------------------------------
# finalize
# ----------------------------------------------------------------------------
xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
touch "$APP"
if [ -x "$APP/Contents/Resources/tapecap" ]; then
  TC_NOTE="tapecap: bundled (self-contained)"
else
  TC_NOTE="tapecap: not bundled — the app will look for it on your PATH at runtime"
fi
echo "Done → $APP  [$MODE_NOTE]"
echo "$TC_NOTE"
open -R "$APP" >/dev/null 2>&1 || true
osascript >/dev/null 2>&1 <<AS || true
display dialog "TapeCap.app is ready in:

$HERE

Mode: $MODE_NOTE
$TC_NOTE

Double-click it to test." buttons {"OK"} default button "OK" with title "TapeCap — build complete"
AS
