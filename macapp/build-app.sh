#!/usr/bin/env bash
# Build a runnable Ownscribe.app with just swiftc + codesign — no Xcode or
# XcodeGen required. (For the normal Xcode workflow use project.yml instead.)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

# --variant NAME builds a second app that coexists with the installed one, so a
# known-good build can be kept as a fallback while a new one is tried.
#
# Three things must differ or the two are not actually independent:
#   app name          - distinguishable in Finder and the menu bar
#   bundle identifier - shared IDs confuse TCC and LaunchServices, and the two
#                       builds would fight over the same permission grants
#   managed root      - otherwise the variant upgrades the stable app's Python
#                       env, so a bad CLI change breaks the fallback too
VARIANT=""
RUN_AFTER=0
while [ $# -gt 0 ]; do
    case "$1" in
        --variant) VARIANT="${2:-}"; shift 2 ;;
        --variant=*) VARIANT="${1#*=}"; shift ;;
        --run) RUN_AFTER=1; shift ;;
        -h|--help)
            echo "usage: $0 [--variant NAME] [--run]"
            echo "  no args         build Ownscribe.app (the stable bundle)"
            echo "  --variant Next  build 'Ownscribe Next.app' alongside it, with its"
            echo "                  own bundle id and its own managed Python env"
            echo "  --run           open the app when the build finishes"
            exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [ -n "$VARIANT" ]; then
    APP_NAME="Ownscribe $VARIANT"
    # Lowercased, spaces stripped — bundle IDs must be reverse-DNS safe.
    SUFFIX="$(printf '%s' "$VARIANT" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')"
    BUNDLE_ID="dev.p4l.ownscribe.menubar.$SUFFIX"
    MANAGED_ROOT_NAME="Ownscribe $VARIANT"
else
    APP_NAME="Ownscribe"
    BUNDLE_ID="dev.p4l.ownscribe.menubar"
    MANAGED_ROOT_NAME="Ownscribe"
fi
APP="$BUILD_DIR/$APP_NAME.app"
# The executable name must not contain spaces — CFBundleExecutable is a file name.
EXEC_NAME="$(printf '%s' "$APP_NAME" | tr -d ' ')"

echo "Building $APP_NAME.app ($ARCH)…"
echo "  bundle id:    $BUNDLE_ID"
echo "  managed env:  ~/Library/Application Support/$MANAGED_ROOT_NAME"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Compile every Swift source into the bundle executable. Source paths contain
# no spaces, so word-splitting the find output is fine (portable to bash 3.2).
# shellcheck disable=SC2046
xcrun -sdk macosx swiftc \
    -O -parse-as-library \
    -target "$TARGET" \
    -o "$APP/Contents/MacOS/$EXEC_NAME" \
    $(find "$SCRIPT_DIR/Sources" -name '*.swift')

# Concrete Info.plist (the Xcode template in Resources/ uses $(VAR) substitutions).
# The usage-description keys below MUST match Resources/Info.plist — the two bundles are
# built by different paths (this script vs. xcodegen) and have drifted before: e4e99da
# dropped NSMicrophoneUsageDescription from the Xcode template only, which SIGABRTs the
# Xcode-built app on its first mic request. A mismatch is checked for after this heredoc.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>${EXEC_NAME}</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<!-- Selects ~/Library/Application Support/<name> for the managed Python env,
	     read by OwnscribeCLI.managedRoot. Keeps a variant build off the stable
	     app's environment. -->
	<key>OWSManagedRootName</key>
	<string>${MANAGED_ROOT_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.15.2</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSMicrophoneUsageDescription</key>
	<string>Ownscribe records your microphone (alongside system audio) so it can transcribe and summarize meetings locally.</string>
	<key>NSScreenRecordingUsageDescription</key>
	<string>Ownscribe records your computer's audio (the other meeting participants) so it can transcribe and summarize meetings locally.</string>
</dict>
</plist>
PLIST

# Guard against the two Info.plists drifting again: both must declare the same set of
# NS*UsageDescription keys. Missing NSMicrophoneUsageDescription is a hard crash (TCC
# SIGABRTs the process), so this is worth failing the build over.
built_keys=$(grep -oE 'NS[A-Za-z]+UsageDescription' "$APP/Contents/Info.plist" | sort -u)
template_keys=$(grep -oE 'NS[A-Za-z]+UsageDescription' "$SCRIPT_DIR/Resources/Info.plist" | sort -u)
if [ "$built_keys" != "$template_keys" ]; then
  echo "error: usage-description keys differ between build-app.sh and Resources/Info.plist" >&2
  echo "  built:    $(echo "$built_keys" | tr '\n' ' ')" >&2
  echo "  template: $(echo "$template_keys" | tr '\n' ' ')" >&2
  exit 1
fi

# Prefer a stable self-signed identity so Screen Recording / Microphone TCC grants persist
# across rebuilds; fall back to ad-hoc (grants reset each rebuild) if it isn't set up. We try
# the identity directly rather than `security find-identity -v`, which hides untrusted
# self-signed certs even though codesign can use them. Create it once with make-signing-cert.sh.
ENT="$SCRIPT_DIR/Resources/Ownscribe.entitlements"
IDENTITY="Ownscribe Local Signing"
if codesign --force --sign "$IDENTITY" --entitlements "$ENT" "$APP" 2>/dev/null; then
    echo "Signed with stable identity \"$IDENTITY\" — TCC grants persist across rebuilds."
else
    codesign --force --sign - --entitlements "$ENT" "$APP"
    echo "Signed ad-hoc — TCC grants reset each rebuild. For persistent grants: bash \"$SCRIPT_DIR/make-signing-cert.sh\""
fi

echo "Built: $APP"
echo "Run with: open \"$APP\"   (or re-run with --run)"

if [ "$RUN_AFTER" -eq 1 ]; then
    open "$APP"
fi
