#!/bin/sh
set -eu
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUT="${SIXM_OUTPUT:-$HERE/Sixm.app}"
mkdir -p "$OUT/Contents/MacOS" "$OUT/Contents/Resources" "$HERE/.build/module-cache"
xcrun swiftc -O -module-cache-path "$HERE/.build/module-cache" -target arm64-apple-macosx14.0 "$HERE/Simulation.swift" "$HERE/DumpInventory.swift" "$HERE/Sandbox.swift" "$HERE/GLB.swift" "$HERE/WorldCell.swift" "$HERE/AssetImporter.swift" "$HERE/main.swift" -framework Cocoa -framework WebKit -framework SceneKit -framework GameController -o "$OUT/Contents/MacOS/Sixm"
cp "$HERE/index.html" "$OUT/Contents/Resources/index.html"
cat > "$OUT/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Sixm</string><key>CFBundleIdentifier</key><string>dev.sixm.prototype</string><key>CFBundleName</key><string>Sixm</string><key>CFBundleShortVersionString</key><string>0.1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
if [ -n "${SIXNG_BIN:-}" ]; then
  : "${SIXNG_SOURCE:?Set SIXNG_SOURCE to the corresponding SixNG source checkout}"
  mkdir -p "$OUT/Contents/Resources/tools"
  cp "$SIXNG_BIN" "$OUT/Contents/Resources/tools/sixng"
  cp "$SIXNG_SOURCE/LICENSE" "$OUT/Contents/Resources/tools/SixNG-LICENSE"
  cp "$SIXNG_SOURCE/THIRD_PARTY_NOTICES.md" "$OUT/Contents/Resources/tools/SixNG-NOTICES.md"
  git -C "$SIXNG_SOURCE" rev-parse HEAD > "$OUT/Contents/Resources/tools/SixNG-COMMIT.txt"
  printf '%s\n' 'https://github.com/holdmysocks/SixNG' > "$OUT/Contents/Resources/tools/SixNG-SOURCE.txt"
fi
codesign --force --deep --sign - "$OUT"
printf '%s\n' "$OUT"
