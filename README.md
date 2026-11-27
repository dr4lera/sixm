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

## Windows launcher

Install Python 3.9+ from python.org, then run `Launch-Windows.cmd` (or `python portable.py`). This opens the same launcher in your browser and supports read-only local dump inspection. It binds only to loopback and validates API tokens and origins. The SceneKit renderer prototype is Mac-only; Windows gameplay and real-asset rendering are not implemented or tested.

## Real asset preview

The Mac app can open a locally converted glTF 2.0 GLB using **Open real asset preview**. It loads static triangle meshes, node transforms, normals, UVs, base-colour textures and basic metallic/roughness factors. Skins, animations, morph targets, specialized game materials, physics and gameplay are not reproduced. External textures remain constrained to the model folder, or the nearest ancestor containing a SixNG `manifest.jsonl`.

A local validation recovered and displayed `phoenix_mid` from `levels.rpf` with 73,431 vertices and 69,276 triangles using SixNG at commit `47250388a583222025d418addf5e32b2f3a6ec18`. No exported content is included here. SixNG is GPL-3.0-only; use its upstream source and notices if distributing that separate tool.

[SixNG upstream](https://github.com/holdmysocks/SixNG) provides local archive carving and conversion. Mac development builds can bundle a separately built helper as described below. Archive carving is not a complete decrypted directory listing.

## Recovery status

A local investigation indexed 523,524 carving entries in `levels.rpf` and 80,406 in `packs.rpf`. These are recovery indexes, not proof of complete archive coverage. `script.rpf` yielded 1,012 XML-like script-data documents. The story script container yielded 2,309 other PSO resources and no documents accepted by that decoder. Script configuration data is not decompiled executable script code.

REA identified the original executable as x86-64 PE. A workspace-local Ghidra provider is installed. Whole-executable analysis has timed out; a bounded native function produced provisional pseudocode, with calling-convention verification still in progress. No game script source or editable engine source has been recovered for Sixm. Original engine files remain in the user's local dump; they are not redistributed here.

The fidelity target is to preserve original recovered assets and data, with custom features in an isolated resource/server layer. Full map streaming, original behavior, distinct player characters, customization, and multiplayer remain development goals.

## Integrated Mac import

The Mac launcher can optionally bundle the separately built SixNG CLI. Set `SIXNG_BIN` to its native executable and `SIXNG_SOURCE` to the matching source checkout when running `build.sh`; the app includes its license, notices, source URL and commit. The source repository includes no game files or extractor binary.

**Import & preview** asks for the local dump folder and a recovered model name (default `phoenix_mid`). It creates/resumes a world archive index, converts one supported drawable/fragment and available textures, then opens the static preview. Cache and outputs go to `~/Library/Application Support/Sixm/Imports/<local-path-hash>`, outside the original dump and app bundle. Cancel stops the helper and leaves resumable data in place.

The same import path can be tested with `Sixm --recover-asset <dump> --asset-name phoenix_mid --asset-work <scratch-folder>`. Invalid model names and missing `levels.rpf` are rejected. This is not full-world conversion or gameplay. The Windows entry point still supports launcher/inspection only.

## Bounded world-cell experiment

`build_cell.py` selects a small world-space group from SixNG placement exports, converts a bounded number of unique model references, and writes `cell.json` with rebased glTF transforms and explicit limitations. It requires the separately built SixNG CLI. Use `--help` for required input paths; the default radius is 40 metres and the default model cap is six.

The Mac asset picker also accepts a generated `cell.json`; `Sixm --validate-cell <cell.json>` validates its geometry without opening a window. Model paths are constrained to the cell folder, transforms must be finite, and manifests are limited to 2,048 instances. This is static assembly, not world streaming, physics, collision, gameplay or an interpreted LOD hierarchy.

A local first sample imported 19 placed instances of three real barrier models, totaling 133,976 vertices and 101,005 triangles. Placement recovery found 2,250,722 entities across 30,789 files; those counts do not establish full rendered-map coverage.

For repeatable visual verification without controlling an existing launcher window, run `Sixm --snapshot-preview <model.glb-or-cell.json> --snapshot-output <preview.png>`. This renders one 1280×800 frame with a fitted camera and default lighting. It is a geometry check, not an FPS or material-fidelity benchmark.
