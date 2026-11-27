#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${SIXM_OUTPUT:-$HERE/Sixm.app}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$HERE/.build/module-cache"
xcrun swiftc -O -module-cache-path "$HERE/.build/module-cache" -target arm64-apple-macosx14.0 "$HERE/Simulation.swift" "$HERE/DumpInventory.swift" "$HERE/Sandbox.swift" "$HERE/GLB.swift" "$HERE/main.swift" -framework Cocoa -framework WebKit -framework SceneKit -framework GameController -o "$OUT/Contents/MacOS/Sixm"
cp "$HERE/index.html" "$OUT/Contents/Resources/index.html"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Sixm</string><key>CFBundleIdentifier</key><string>dev.sixm.prototype</string><key>CFBundleName</key><string>Sixm</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --deep --sign - "$OUT"
printf '%s\n' "$OUT"
