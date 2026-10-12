#!/bin/bash
# Builds Shotshelf.app with the Xcode Command Line Tools (no Xcode project needed).
#   ./build.sh              build for this Mac
#   ./build.sh --universal  build for Apple silicon and Intel
#   ./build.sh --install    build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Shotshelf.app
ARCHS=("$(uname -m)")
INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --universal) ARCHS=(arm64 x86_64) ;;
    --install) INSTALL=1 ;;
  esac
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj

BINS=()
for arch in "${ARCHS[@]}"; do
  echo "Compiling for $arch..."
  swiftc -O -parse-as-library -target "$arch-apple-macos14.0" Sources/*.swift -o "build/obj/Shotshelf-$arch"
  BINS+=("build/obj/Shotshelf-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Shotshelf"

echo "Compiling command-line tool..."
CLI_SOURCES=$(ls Sources/*.swift | grep -v -e App.swift -e ContentView.swift -e GridView.swift -e Viewer.swift -e Triage.swift -e Panels.swift -e Thumbnails.swift -e Library.swift -e Windows.swift -e Notifier.swift -e HotKey.swift)
cp tools/cli.swift build/obj/main.swift
swiftc -O -target "$(uname -m)-apple-macos14.0" $CLI_SOURCES build/obj/main.swift -o build/shotshelf
cp Resources/rules.default.json build/

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/rules.default.json "$APP/Contents/Resources/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with a stable local identity if you have one, so macOS remembers folder permissions across
# rebuilds (see README). Otherwise sign ad hoc.
IDENTITY="${SHOTSHELF_SIGN_IDENTITY:-Shotshelf Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null
else
  codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
echo "Built $APP"

if [ "$INSTALL" = 1 ]; then
  osascript -e 'quit app "Shotshelf"' 2>/dev/null || true
  rm -rf /Applications/Shotshelf.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/Shotshelf.app"
fi
