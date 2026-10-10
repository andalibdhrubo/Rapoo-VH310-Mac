#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'Run this on your Apple Silicon Mac.'; exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo 'Apple Command Line Tools are required. Run: xcode-select --install'; exit 1
fi
APP="$PWD/build/Rapoo Audio Control Mac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -arch arm64 -mmacosx-version-min=14.4 -O3 -c Sources/binaural.c -o "$PWD/build/binaural.o"
xcrun clang -arch arm64 -mmacosx-version-min=14.4 -O3 -c Sources/MicDSP.c -o "$PWD/build/mic.o"
xcrun clang -arch arm64 -mmacosx-version-min=14.4 -O3 -c Sources/Surround.c -o "$PWD/build/surround.o"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.4 -O \
  -import-objc-header Sources/binaural.h Sources/main.swift Sources/Microphone.swift Sources/SurroundPlayer.swift "$PWD/build/binaural.o" "$PWD/build/mic.o" "$PWD/build/surround.o" -o "$APP/Contents/MacOS/RapooMac" \
  -framework AppKit -framework WebKit -framework AVFoundation \
  -framework CoreAudio -framework AudioToolbox -framework CoreMedia
cp -R Resources/. "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
echo "Built: $APP"
open "$APP"
