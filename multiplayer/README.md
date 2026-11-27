# Sixm multiplayer development layer

Python 3.9+ server, standard library only; WebGL 2 browser client for Windows and macOS. The server advances movement at 60 Hz and broadcasts player state at 20 Hz. Rendering interpolates between snapshots. These rates do not guarantee rendered game FPS.

## Run

```sh
python3 -B multiplayer/server.py --maps /path/to/maps --map your-map --port 6022
```

Open `http://127.0.0.1:6022` in a WebGL 2 browser. The Windows portable package includes `Play-Windows.cmd` to open a server URL and `Start-Server-Windows.cmd` to run a server. Python 3.9+ is required for these scripts; joining a remote server's browser client requires only the browser. The package is not a native Windows game executable. Actual Windows OS execution has not been verified here.

`--host 0.0.0.0` listens on the host's network interfaces when the operator wants remote players. `SIXM_SERVER_TOKEN` optionally requires an access token at join. Default binding is loopback. `--max-players` accepts 1–32; default 16. `--no-console` runs without the interactive console.

The bundled `coast` and `courtyard` resources are authored test geometry, not GTA assets. No original game content is bundled. The local recovered-airport validation used a separate map outside this source tree with 13 recovered models, 94 instances and 555 mesh parts. Original specialized materials, skeletal animation, missions and game physics are unfinished. Imported meshes currently have no server collision; server box collision applies only to explicitly configured map boxes.

## Operator controls

Console commands:

```text
maps
map courtyard
feature vehicles off
feature chat on
players
announce Your message here
quit
```

`announce` is supplied by the coast example server resource. Switching maps validates the new configuration before changing the active map, unloads the previous resources, loads new resources and respawns connected players. Map resources can supply their own commands and custom events. There is no remote filesystem upload or network administrator API.

## Maps and assets

Each resource is a directory under `--maps`, containing `map.json`:

```json
{
  "format": "sixm-map-v1",
  "name": "My world",
  "spawns": [[0,0,0], [3,0,0]],
  "scene": "cell.json",
  "debugAvatars": false,
  "features": {"chat": true, "vehicles": false, "characters": false},
  "movement": {"walkSpeed": 5, "driveSpeed": 20},
  "background": [0.12,0.16,0.23],
  "serverScripts": ["resources/server.py"],
  "clientScripts": ["resources/client.js"],
  "shader": {"vertex": "shaders/world.vert", "fragment": "shaders/world.frag"}
}
```

All fields after `format` are optional. `scene` accepts a converted static GLB or Sixm `cell.json`. Keep its referenced models and textures inside the resource directory, preserving their relative paths. Copying a converted cell's output directory into a map resource and adding `map.json` is sufficient. A client may instead choose matching converted local map files with the folder picker; those file contents stay local. Raw Xbox RPF files are not directly loaded by this browser renderer.

Static mesh support includes triangle geometry, transforms, normals, UVs and base-colour textures. It does not reproduce specialized game materials, skinning, animation or physics. Server-owned content may be supplied in arbitrary map resources using these supported formats. Original game assets and derived content must stay out of this source repository.

Optional `boxes` entries have `position`, `size`, `color` arrays and a `collision` boolean. These provide authored test geometry and simple server collision. They are independent of imported meshes.

## Shaders

Servers can replace the vertex and fragment GLSL ES 3.00 programs. Shader attributes are `position` at location 0, `normal` at 1, and `uv` at 2. Standard uniforms are `model`, `viewProjection`, `color`, `baseTexture` and `textured`. Operators can supply custom uniforms and rendering through client resources. Compilation errors are reported and fall back to the default shader. The coast resource includes editable examples. Source limits are 64 KB per shader stage.

## Server resources

`serverScripts` are operator-installed Python files with ordinary access to the server process. They are trusted server code, not a sandbox. Optional synchronous hooks:

```python
def on_load(server): pass
def on_unload(server): pass
def on_tick(server, dt): pass
def on_join(server, peer): pass
def on_leave(server, peer): pass
def on_message(server, peer, message): return False
```

Return true from `on_message` when a resource handles a custom event. `server.broadcast(dict(...))`, `peer.send(dict(...))`, `server.register_command(name, callback)`, `server.change_map(id)` and server-owned state are available. Operators can change or replace behavior through normal Python code. A failing hook is reported and its module is removed from active hooks. Blocking scripts can stall the server; no claim of production isolation is made. Server Python files are not exposed through the map download route.

## Client resources

`clientScripts` execute as browser ES modules with normal page/WebGL access. `window.Sixm` exposes:

- `on(type, callback)` → unsubscribe function; events include `world`, `state`, `disconnect`, `unload` and custom message types.
- `send(message)` and `log(text)`.
- `registerRender(callback)` → unsubscribe function; receives time, delta time, view/projection matrix and server snapshot.
- `renderer.gl`, `mesh`, `transform`, `multiply`, `draw`, `createProgram`, `defaultProgram` and the active `program`.
- Read-only accessors `state` and `playerId`.

Clean up timers, listeners and custom GPU resources on `unload`. These are custom extension interfaces, not compatibility with FiveM's existing scripting runtime. Four debug character markers and a box vehicle are available only for testing. They are not recovered GTA characters or vehicle physics.

## Validation

```sh
python3 -B -m unittest discover -s multiplayer/tests -v
```

Tests use actual local WebSocket connections for two clients, shared movement, client-position spoof rejection, chat, resource events, feature disabling, map switching, token rejection, malformed input and resource-path controls. Browser validation also confirmed two connected clients and shared chat. A separate local test displayed the real recovered airport/car geometry with no authored debug avatars. Browser-reported requestAnimationFrame timing is not a full-game benchmark or GPU presentation measurement.
