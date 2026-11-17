#!/bin/sh
# Builds dist/ClaudeUsageBar.app (ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=dist/ClaudeUsageBar.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/ClaudeUsageBar" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
codesign --force --sign - "$app"
echo "$app"
