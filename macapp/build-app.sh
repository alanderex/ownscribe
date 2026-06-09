#!/usr/bin/env bash
# Build a runnable Ownscribe.app with just swiftc + codesign — no Xcode or
# XcodeGen required. (For the normal Xcode workflow use project.yml instead.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP="$BUILD_DIR/Ownscribe.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

echo "Building Ownscribe.app ($ARCH)…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile every Swift source into the bundle executable. Source paths contain
# no spaces, so word-splitting the find output is fine (portable to bash 3.2).
# shellcheck disable=SC2046
xcrun -sdk macosx swiftc \
    -O -parse-as-library \
    -target "$TARGET" \
    -o "$APP/Contents/MacOS/Ownscribe" \
    $(find "$SCRIPT_DIR/Sources" -name '*.swift')

# Concrete Info.plist (the Xcode template in Resources/ uses $(VAR) substitutions).
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>Ownscribe</string>
	<key>CFBundleIdentifier</key>
	<string>dev.p4l.ownscribe.menubar</string>
	<key>CFBundleName</key>
	<string>Ownscribe</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.12.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Ownscribe records your microphone (alongside system audio) so it can transcribe and summarize meetings locally.</string>
</dict>
</plist>
PLIST

# Ad-hoc sign with entitlements so TCC has a stable identity for this build.
codesign --force --sign - \
    --entitlements "$SCRIPT_DIR/Resources/Ownscribe.entitlements" \
    "$APP" >/dev/null 2>&1

echo "Built: $APP"
echo "Run with: open \"$APP\"   (or: ./macapp/build-app.sh --run)"

if [[ "${1:-}" == "--run" ]]; then
    open "$APP"
fi
