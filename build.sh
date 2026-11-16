#!/bin/bash
# Build Blinky.app.
#
#   ./build.sh              build build/Blinky.app for this Mac's architecture
#   ./build.sh --universal  build an arm64 + x86_64 binary
#   ./build.sh --zip        also pack build/Blinky-<version>.zip (implies --universal)
#   ./build.sh --install    copy to ~/Applications and launch
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(cat VERSION)
BUNDLE_ID=io.github.asmodaip.blinky
UNIVERSAL=0; ZIP=0; INSTALL=0
for a in "$@"; do
  case $a in
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1; UNIVERSAL=1 ;;
    --install) INSTALL=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

APP=build/Blinky.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $UNIVERSAL == 1 ]]; then
  for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx14.4"
  done
  lipo -create -output "$APP/Contents/MacOS/Blinky" \
    .build/arm64-apple-macosx/release/Blinky .build/x86_64-apple-macosx/release/Blinky
else
  swift build -c release
  cp .build/release/Blinky "$APP/Contents/MacOS/Blinky"
fi

cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Blinky</string>
  <key>CFBundleDisplayName</key><string>Blinky</string>
  <key>CFBundleExecutable</key><string>Blinky</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Licensed under GPL-3.0</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>To move breaks before meetings and not interrupt calls.</string>
  <key>NSFocusStatusUsageDescription</key><string>To show gentle breaks while a Focus is on.</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>blinky</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# Ad-hoc signature: no Apple Developer account needed (see README → Install).
codesign --force --deep --sign - "$APP"
echo "Built $APP ($VERSION)"

if [[ $ZIP == 1 ]]; then
  (cd build && rm -f "Blinky-$VERSION.zip" && ditto -c -k --keepParent Blinky.app "Blinky-$VERSION.zip")
  echo "Packed build/Blinky-$VERSION.zip"
fi

if [[ $INSTALL == 1 ]]; then
  mkdir -p ~/Applications
  pkill -x Blinky 2>/dev/null && while pgrep -x Blinky >/dev/null; do sleep 0.2; done || true
  rm -rf ~/Applications/Blinky.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/Blinky.app
  echo "Installed ~/Applications/Blinky.app"
fi
