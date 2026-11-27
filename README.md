# Sixm

A Windows/macOS multiplayer framework preview with a Vice City-inspired client. **Original-game reconstruction is paused pending an official PC version.** This project is not a finished GTA VI port and does not include game content, a game engine source recovery, or FiveM runtime compatibility, but  is a framework similar to it in preparation for the release of the pc story mode.

## Downloads

Use [GitHub Releases](https://github.com/dr4lera/sixm/releases) for the Windows executables/ZIP and Apple Silicon Mac DMG. The release workflow builds on Windows and macOS, tests the outputs and publishes checksums. Releases are development previews; the Mac app is ad hoc signed and not notarized.

- Windows: `Sixm.exe` opens a server's browser client. `SixmServer.exe` hosts a server. Python is bundled in both executables.
- macOS: drag `Sixm.app` from the DMG into Applications. The launcher can open the cross-platform browser client and includes experimental native static-asset tools.
- Rendering uses a WebGL 2 browser. No original assets or extractor are included in release packages.

## Server and resources

The server owns movement at 60 Hz and sends snapshots at 20 Hz. The browser interpolates player positions. Operators control maps, static assets, shader programs, feature switches and custom resources. See [the resource API](multiplayer/README.md).

```sh
python3 -B multiplayer/server.py --port 6020
# Open http://127.0.0.1:6020
```

For custom maps:

```sh
python3 -B multiplayer/server.py --maps /path/to/maps --map your-map
```

Server resources are trusted Python code; client resources are browser JavaScript with WebGL access. Editable GLSL shader examples and two clearly labelled authored test maps are included. Imported GLB/cell scenes are static; animation, original materials, missions, game physics, imported mesh collision and full world streaming remain unfinished.

## Build releases

Run **Actions → Build and release Sixm → Run workflow** and provide a preview tag such as `v0.2.0-preview`, or push a `v*` tag. The workflow builds Windows client/server EXEs and a Mac DMG, runs tests, and attaches the outputs and `SHA256SUMS.txt` to a prerelease. It uses the repository's normal Actions token; no personal token or signing identity is stored.

Local platform builds:

```powershell
# Windows, Python 3.12
./packaging/build_windows.ps1
```

```sh
# Apple Silicon Mac, Xcode Command Line Tools
sh packaging/build_macos.sh
```

## Native Mac experiments

`sh build.sh` builds the native launcher and SceneKit test tools. `Sixm --self-test` checks fixed-step simulation and importer limits. Static GLB and bounded cell import can be verified using `--validate-glb`, `--validate-cell`, or `--snapshot-preview ... --snapshot-output ...`.

The optional separately built [SixNG](https://github.com/holdmysocks/SixNG) helper can be included with `SIXNG_BIN` and `SIXNG_SOURCE`. Its license/notices and source identity are included when bundled. It is not included in the default release workflow. Dump inspection is read-only; converted content stays local. A small local recovered-asset scene was displayed during development; it is not part of this repository or proof of complete game recovery.

## Tests

```sh
python3 -B -m unittest discover -s multiplayer/tests -v
```

The Windows build additionally executes the packaged client/server, checks bundled web resources and connects two test clients. Mac builds run native self-tests, verify the app signature and verify the DMG. Browser-reported frame timing from small static scenes is not a full-game benchmark.
