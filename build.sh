#!/bin/bash
# Builds Clippy.app (clipboard history + KeepAwake) from the .swift files and the three PNGs next to this script.
# Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP="Clippy.app"
ICON_INACTIVE="moon_inactive.png"
ICON_ACTIVE="moon_active.png"
ICON_SPACE="spaceship.png"      # optional: shown while hidden files / Library are visible

# moon_active.png has more transparent padding than moon_inactive.png (moon = 717px of 1024,
# versus 939px for the inactive ring), so it would look ~25% smaller in the menu bar.
# Cropping the centre of the active image to this size makes both draw at the same size.
# If you replace the PNGs, set this to: 1024 * (moon width / inactive ring width).
ACTIVE_CROP=782

for f in main.swift Core.swift KeepAwake.swift Panel.swift Settings.swift; do
  if [ ! -f "$f" ]; then
    echo "Error: $f not found in $(pwd). Keep all the .swift files next to this script."
    exit 1
  fi
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "Error: swiftc not found. Install the command line tools with: xcode-select --install"
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
RESOURCES="$APP/Contents/Resources"

# --- Icons ---
if [ -f "$ICON_INACTIVE" ] && [ -f "$ICON_ACTIVE" ]; then
  echo "Bundling moon icons ..."

  # Menu bar icons: 36px PNGs, drawn at 18pt (2x) by the app.
  sips --cropToHeightWidth $ACTIVE_CROP $ACTIVE_CROP "$ICON_ACTIVE" --out "$TMP/active_cropped.png" >/dev/null
  sips -Z 36 "$ICON_INACTIVE"            --out "$RESOURCES/icon.png"        >/dev/null
  sips -Z 36 "$TMP/active_cropped.png"   --out "$RESOURCES/icon_active.png" >/dev/null
  if [ -f "$ICON_SPACE" ]; then
    sips -Z 36 "$ICON_SPACE" --out "$RESOURCES/icon_space.png" >/dev/null
  else
    echo "Note: $ICON_SPACE not found - hidden-files mode will use the normal moon icons."
  fi

  # App icon (Finder / Login Items). The iconset lives in a temp dir, not inside the app.
  ICONSET="$TMP/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -Z $size       "$ICON_INACTIVE" --out "$ICONSET/icon_${size}x${size}.png"    >/dev/null
    sips -Z $((size*2)) "$ICON_INACTIVE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RESOURCES/AppIcon.icns"
else
  echo "Warning: $ICON_INACTIVE / $ICON_ACTIVE not found - the app will show a text symbol instead of the moon."
fi

# --- Info.plist ---
# The bundle id stays local.clippy so the Clippy settings and history you already have carry over.
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.clippy</string>
    <key>CFBundleName</key><string>Clippy</string>
    <key>CFBundleExecutable</key><string>Clippy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleShortVersionString</key><string>2.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# -Osize: optimize for size, -wmo: whole-module optimization, -dead_strip: drop unused code
swiftc -Osize -wmo -swift-version 5 -Xlinker -dead_strip \
  main.swift Core.swift KeepAwake.swift Panel.swift Settings.swift \
  -o "$APP/Contents/MacOS/Clippy" \
  -framework AppKit -framework Carbon -framework IOKit -framework ServiceManagement
# Use Apple's strip explicitly (a conda/cctools-port strip earlier on PATH can break on folder names with spaces)
if [ -x /usr/bin/strip ]; then STRIP=/usr/bin/strip; else STRIP=strip; fi
"$STRIP" -Sx "$APP/Contents/MacOS/Clippy" || true
rm -f "$APP/Contents/MacOS/Clippy.strip"
codesign --force --sign - "$APP"

echo "Built $APP  ->  move it to /Applications, then: open /Applications/$APP"
