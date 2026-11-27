# Sixm

An independent native Apple Silicon sandbox prototype with a Vice City-inspired, browser-style launcher. Bring your own local extracted Xbox dump. No game executable, assets, keys, or recovered proprietary source are bundled.

## Current state

This is an early foundation, not a finished GTA VI port or a complete multiplayer client.

- Native macOS launcher using WKWebView with local HTML; no hosted web service.
- Read-only local dump inspection: PE signature, RPF9 archive headers, file/byte counts. Files remain in place.
- Native procedural SceneKit street with walking, driving, four placeholder character presets, paint switching, and keyboard/gamepad input.
- Fixed 60 Hz simulation, render interpolation, bounded catch-up after pauses, live FPS and p95 frame timing.
- Simulation invariance tested at 30/60/120/144 rendered FPS.

**Not implemented:** RPF9 directory decoding or extraction, conversion of models/materials/skeletons/animations/collisions, GTA map streaming, original physics/AI/missions, network synchronization, server scripting, persistence, and a complete customization system.

The archive inspector does not claim archive integrity or authenticity from a header. A local dump is not automatically recovered engine source. A 60 Hz simulation does not guarantee 60 rendered FPS with game content.

## Build

Requires Apple Silicon, macOS 14+, and Xcode Command Line Tools with the macOS SDK. No third-party packages.

```sh
sh build.sh
open Sixm.app
```

```sh
./Sixm.app/Contents/MacOS/Sixm --self-test
./Sixm.app/Contents/MacOS/Sixm --inspect '/path/to/extracted/Xbox-dump'
./Sixm.app/Contents/MacOS/Sixm --smoke-render --report /tmp/sixm-render.json
```

For a different app output location, set `SIXM_OUTPUT` when building. The local build is ad hoc signed for development, not notarized for distribution.

## Prototype controls

W/S: forward/reverse. A/D: turn. E: enter/exit the placeholder car. C: cycle character presets. V: cycle paint. Gamepad: left stick for movement, triggers for throttle/brake, south face button to enter/exit. Character and vehicle changes are temporary.

## Next milestones

1. A bounded, validated RPF9 directory reader and inventory. Establish compression and resource versions before exporting anything.
2. Convert one mesh/material with an asset provenance manifest; validate skeleton and animation separately.
3. One streamed test cell with measured CPU/GPU/memory budgets.
4. Authoritative server and two-client movement before adding persistence and server resources.
5. Extend to distinct characters, outfits, vehicles and customization. Full-map support depends on the streaming importer; it is not implemented yet.

Untrusted archives should be parsed with bounded lengths and offsets. Keep local dumps and derived content out of this source repository.
