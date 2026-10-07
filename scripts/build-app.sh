#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift build --configuration "$configuration" --arch arm64
binary_directory=$(swift build --configuration "$configuration" --arch arm64 --show-bin-path)
app_path="$PWD/build/LLM Meter.app"
mkdir -p "$PWD/build"
staging_directory=$(mktemp -d "$PWD/build/.package.XXXXXX")
staged_app="$staging_directory/LLM Meter.app"
icon_directory=$(mktemp -d "${TMPDIR:-/tmp}/llm-meter-icons.XXXXXX")
trap 'rm -rf "$icon_directory" "$staging_directory"' EXIT
mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_directory/LLMMeter" "$staged_app/Contents/MacOS/LLMMeter"
cp Resources/Info.plist "$staged_app/Contents/Info.plist"
# Optional release stamp supplied by CI; local builds keep the committed version.
if [ -n "${VERSION:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
        "$staged_app/Contents/Info.plist"
fi
if [ -n "${BUILD_NUMBER:-}" ]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" \
        "$staged_app/Contents/Info.plist"
fi
cp -R "$binary_directory/LLMMeter_LLMMeterApp.bundle" "$staged_app/Contents/Resources/"
mkdir -p "$icon_directory/AppIcon.iconset"
"$binary_directory/LLMMeter" --export-icon "$icon_directory/icon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_directory/icon.png" --out "$icon_directory/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_directory/icon.png" --out "$icon_directory/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_directory/AppIcon.iconset" -o "$staged_app/Contents/Resources/AppIcon.icns"
# An ad-hoc signature supports local development. Supply a Developer ID identity for distribution.
identity="${SIGNING_IDENTITY:--}"
codesign --force --options runtime --sign "$identity" "$staged_app"
codesign --verify --strict "$staged_app"
# Do not truncate an executable that may still be running.
if [ -d "$app_path" ]; then mv "$app_path" "$staging_directory/previous.app"; fi
mv "$staged_app" "$app_path"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$PWD/build/LLM-Meter-arm64.zip"
printf 'Built %s\n' "$app_path"
