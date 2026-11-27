#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
mkdir -p build/dmg
SIXM_OUTPUT="$ROOT/build/dmg/Sixm.app" sh build.sh
build/dmg/Sixm.app/Contents/MacOS/Sixm --self-test
codesign --verify --deep --strict build/dmg/Sixm.app
[ -L build/dmg/Applications ] || ln -s /Applications build/dmg/Applications
hdiutil create -volname Sixm -srcfolder build/dmg -ov -format UDZO build/Sixm-macOS-arm64.dmg
hdiutil verify build/Sixm-macOS-arm64.dmg
shasum -a 256 build/Sixm-macOS-arm64.dmg
