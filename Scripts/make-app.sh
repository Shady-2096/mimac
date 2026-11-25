#!/bin/sh
# Assembles dist/Mimac.app from the SwiftPM release build, then installs it to
# /Applications so the app you launch is always the app you just built.
# A dev-grade bundle (ad-hoc signed); Phase 7 replaces this with a signed,
# notarized Xcode build.
#
#   Scripts/make-app.sh              build and install (quits a running Mimac)
#   Scripts/make-app.sh --no-install build the bundle into dist/ only
set -e
cd "$(dirname "$0")/.."

INSTALL=1
[ "$1" = "--no-install" ] && INSTALL=0

swift build -c release

APP=dist/Mimac.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ ! -f dist/AppIcon.icns ]; then
  swift Scripts/make-icon.swift dist/AppIcon.iconset
  iconutil -c icns dist/AppIcon.iconset -o dist/AppIcon.icns
  rm -rf dist/AppIcon.iconset
fi

cp .build/release/Mimac "$APP/Contents/MacOS/Mimac"
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resources (the CLI tool icons). Bundle.module looks in
# Contents/Resources; newer toolchains no longer fall back to the absolute
# build directory, so without this copy the app traps the first time a row
# shows a tool icon.
RESOURCES=$(ls -d .build/release/*_Mimac.bundle 2>/dev/null | head -1)
if [ -z "$RESOURCES" ]; then
  echo "make-app: no *_Mimac.bundle in .build/release; the app would crash on tool icons" >&2
  exit 1
fi
cp -R "$RESOURCES" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Mimac</string>
    <key>CFBundleIdentifier</key>
    <string>com.mimac.app</string>
    <key>CFBundleName</key>
    <string>Mimac</string>
    <key>CFBundleDisplayName</key>
    <string>Mimac</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"
echo "Built $APP"

[ "$INSTALL" = "1" ] || exit 0

# Install. Both bundles declare com.mimac.app, so a copy left running from the
# project tree shadows the installed one and makes a good install look like it
# failed. Quit every instance, replace the installed bundle, then leave
# /Applications as the only registration so Spotlight has one answer.
INSTALLED=/Applications/Mimac.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

osascript -e 'quit app "Mimac"' >/dev/null 2>&1 || true
sleep 1
pkill -f "Mimac.app/Contents/MacOS/Mimac" >/dev/null 2>&1 || true

rm -rf "$INSTALLED"
cp -R "$APP" "$INSTALLED"

"$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true

echo "Installed $INSTALLED (open -b com.mimac.app to launch it)"
