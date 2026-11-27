#!/usr/bin/env python3
"""Sixm development server. Python 3.9+, no third-party dependencies."""
import argparse
import asyncio
import base64
import hashlib
import hmac
import importlib.util
import json
import math
import mimetypes
import os
from pathlib import Path
import re
import secrets
import struct
import time
import webbrowser
import sys

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent
STEP = 1 / 60
MAX_MESSAGE = 8192


def encode(value):
    return json.dumps(value, separators=(',', ':'), allow_nan=False).encode()


def frame(payload, opcode=1):
    n = len(payload)
    length = bytes([n]) if n < 126 else b'\x7e'+struct.pack('!H', n) if n < 65536 else b'\x7f'+struct.pack('!Q', n)
    return bytes([0x80 | opcode]) + length + payload


async def read_frame(reader):
    a, b = await reader.readexactly(2)
    opcode = a & 15
    if a & 0x70 or not a & 0x80 or not b & 0x80 or opcode not in (1, 8, 9, 10):
        raise ValueError('Unsupported WebSocket frame')
    n = b & 127
    if n == 126:
        n, = struct.unpack('!H', await reader.readexactly(2))
        if n < 126:
            raise ValueError('Noncanonical length')
    elif n == 127:
        n, = struct.unpack('!Q', await reader.readexactly(8))
        if n < 65536:
            raise ValueError('Noncanonical length')
    if n > MAX_MESSAGE or (opcode >= 8 and (n > 125 or (opcode == 8 and n == 1))):
        raise ValueError('Frame exceeds limits')
    mask = await reader.readexactly(4)
    data = await reader.readexactly(n)
    return opcode, bytes(x ^ mask[i % 4] for i, x in enumerate(data))


def finite(value, minimum, maximum):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError('Expected finite number')
    return max(minimum, min(maximum, value))


def confined(root, relative):
    path = (root / relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError('Path escapes resource')
    return path


class MapResource:
    def __init__(self, root, identifier):
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,40}', identifier):
            raise ValueError('Invalid map ID')
        self.directory = confined(root, identifier)
        path = self.directory / 'map.json'
        if path.stat().st_size > 1024 * 1024:
            raise ValueError('Map configuration too large')
        self.config = json.loads(path.read_text(encoding='utf-8'))
        if self.config.get('format') != 'sixm-map-v1':
            raise ValueError('Expected sixm-map-v1')
        self.identifier = identifier
        self.name = str(self.config.get('name', identifier))[:60]
        spawns = self.config.get('spawns', [[0, 0, 0]])
        if not isinstance(spawns, list) or not 1 <= len(spawns) <= 64:
            raise ValueError('Invalid spawns')
        self.spawns = []
        for spawn in spawns:
            if not isinstance(spawn, list) or len(spawn) != 3:
                raise ValueError('Invalid spawn')
            self.spawns.append([finite(x, -100000, 100000) for x in spawn])
        self.features = dict(chat=True, vehicles=True, characters=True)
        for key, value in self.config.get('features', {}).items():
            if key not in self.features or not isinstance(value, bool):
                raise ValueError('Unknown feature or invalid switch')
            self.features[key] = value
        movement = self.config.get('movement', {})
        self.walk_speed = finite(movement.get('walkSpeed', 5), 0.1, 20)
        self.drive_speed = finite(movement.get('driveSpeed', 20), 1, 50)
        self.boxes = self.config.get('boxes', [])
        if not isinstance(self.boxes, list) or len(self.boxes) > 2048:
            raise ValueError('Map exceeds box budget')
        for box in self.boxes:
            for key in ('position', 'size', 'color'):
                values = box.get(key)
                if not isinstance(values, list) or len(values) != 3:
                    raise ValueError('Invalid map box')
                for value in values:
                    finite(value, -100000, 100000)
            if any(x <= 0 for x in box['size']):
                raise ValueError('Box dimensions must be positive')
        scene = self.config.get('scene')
        if scene is not None:
            if not isinstance(scene, str) or not confined(self.directory, scene).is_file():
                raise ValueError('Missing or invalid scene')
        for field, suffix, maximum in [('serverScripts', '.py', 256*1024), ('clientScripts', '.js', 256*1024)]:
            scripts = self.config.get(field, [])
            if not isinstance(scripts, list) or len(scripts) > 16:
                raise ValueError('Invalid resource script list')
            for script in scripts:
                file = confined(self.directory, script)
                if file.suffix != suffix or not file.is_file() or file.stat().st_size > maximum:
                    raise ValueError('Invalid resource script')
        shader = self.config.get('shader')
        if shader is not None:
            for stage in ('vertex', 'fragment'):
                file = confined(self.directory, shader[stage])
                if not file.is_file() or file.stat().st_size > 65536:
                    raise ValueError('Invalid shader resource')

    def public(self):
        return dict(id=self.identifier, name=self.name, features=self.features,
                    scene=self.config.get('scene'), boxes=self.boxes,
                    clientScripts=self.config.get('clientScripts', []), shader=self.config.get('shader'),
                    debugAvatars=self.config.get('debugAvatars', True),
                    background=self.config.get('background', [0.035, 0.045, 0.09]))

    def blocked(self, x, z, radius):
        for box in self.boxes:
            if not box.get('collision', False):
                continue
            p, s = box['position'], box['size']
            if abs(x-p[0]) < s[0]/2+radius and abs(z-p[2]) < s[2]/2+radius:
                return True
        return False


class Peer:
    def __init__(self, writer, name):
        self.writer, self.name = writer, name
        self.id = secrets.token_hex(8)
        self.x = self.y = self.z = self.heading = self.speed = 0.0
        self.character, self.driving, self.seq = 0, False, -1
        self.throttle = self.steering = 0.0
        self.last_seen = self.last_input = time.monotonic()
        self.credit, self.credit_time = 90.0, time.monotonic()

    def send(self, value):
        if self.writer.is_closing():
            return
        if self.writer.transport.get_write_buffer_size() > 256*1024:
            self.writer.close()
            return
        self.writer.write(frame(encode(value)))

    def public(self):
        return dict(id=self.id, name=self.name, x=self.x, y=self.y, z=self.z,
                    heading=self.heading, speed=self.speed, character=self.character, driving=self.driving, seq=self.seq)


class SixmServer:
    def __init__(self, host='127.0.0.1', port=6020, maps=None, map_id='coast', token='', max_players=16):
        self.host, self.port = host, port
        self.maps = Path(maps or ROOT/'maps').resolve()
        self.resource = MapResource(self.maps, map_id)
        self.token, self.max_players = token, max_players
        self.peers, self.connections = {}, 0
        self.tick, self.revision = 0, 1
        self.listener = self.loop_task = None
        self.plugins, self.commands = [], {}

    async def start(self):
        self.load_resources()
        self.listener = await asyncio.start_server(self.handle, self.host, self.port, limit=16384)
        self.port = self.listener.sockets[0].getsockname()[1]
        self.loop_task = asyncio.create_task(self.simulate())
        return self

    async def stop(self):
        self.hook('on_unload')
        self.listener.close()
        await self.listener.wait_closed()
        self.loop_task.cancel()
        try:
            await self.loop_task
        except asyncio.CancelledError:
            pass
        for peer in list(self.peers.values()):
            peer.writer.close()

    def state(self):
        return dict(type='state', tick=self.tick, revision=self.revision,
                    players=[p.public() for p in self.peers.values()])

    def world(self):
        return dict(type='world', revision=self.revision, map=self.resource.public())

    def broadcast(self, message):
        for peer in list(self.peers.values()):
            peer.send(message)

    def register_command(self, name, callback):
        if not re.fullmatch(r'[a-z][a-z0-9_-]{0,31}', name) or name in ('maps', 'map', 'feature', 'players', 'quit'):
            raise ValueError('Invalid or reserved command')
        self.commands[name] = callback

    def load_resources(self):
        self.plugins, self.commands = [], {}
        for relative in self.resource.config.get('serverScripts', []):
            try:
                path = confined(self.resource.directory, relative)
                spec = importlib.util.spec_from_file_location('sixm_resource_'+secrets.token_hex(8), path)
                module = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(module)
                self.plugins.append(module)
                callback = getattr(module, 'on_load', None)
                if callback:
                    callback(self)
            except Exception as error:
                print('Resource failed to load:', relative, str(error), flush=True)

    def hook(self, name, *args):
        handled = False
        for module in list(self.plugins):
            callback = getattr(module, name, None)
            if callback:
                try:
                    handled = bool(callback(self, *args)) or handled
                except Exception as error:
                    print('Resource hook failed:', name, str(error), flush=True)
                    self.plugins.remove(module)
        return handled

    def spawn(self, peer, index):
        peer.x, peer.y, peer.z = self.resource.spawns[index % len(self.resource.spawns)]
        peer.speed = peer.heading = peer.throttle = peer.steering = 0
        peer.driving = False

    def change_map(self, identifier):
        resource = MapResource(self.maps, identifier)  # Validate before switching.
        self.hook('on_unload')
        self.resource = resource
        self.load_resources()
        self.revision += 1
        for i, peer in enumerate(self.peers.values()):
            self.spawn(peer, i)
        self.broadcast(self.world())
        self.broadcast(self.state())

    def feature(self, name, enabled):
        if name not in self.resource.features or not isinstance(enabled, bool):
            raise ValueError('Unknown feature')
        self.resource.features[name] = enabled
        if name == 'vehicles' and not enabled:
            for peer in self.peers.values():
                peer.driving = False
        self.revision += 1
        self.broadcast(self.world())
        self.broadcast(self.state())

    def step(self, now):
        for peer in list(self.peers.values()):
            if now-peer.last_seen > 15:
                peer.writer.close()
                continue
            throttle, steering = (peer.throttle, peer.steering) if now-peer.last_input <= 0.35 else (0, 0)
            target = throttle*(self.resource.drive_speed if peer.driving else self.resource.walk_speed)
            peer.speed += (target-peer.speed)*min(1, STEP*(2.8 if peer.driving else 12))
            peer.heading += steering*STEP*(min(abs(peer.speed)/5, 1.5) if peer.driving else 2.4)
            x = peer.x+math.sin(peer.heading)*peer.speed*STEP
            z = peer.z+math.cos(peer.heading)*peer.speed*STEP
            if not self.resource.blocked(x, z, 0.9 if peer.driving else 0.3):
                peer.x, peer.z = x, z
            else:
                peer.speed = 0
        self.tick += 1
        self.hook('on_tick', STEP)

    async def simulate(self):
        previous, accumulator = time.monotonic(), 0.0
        while True:
            now = time.monotonic()
            accumulator += min(now-previous, 0.25)
            previous = now
            count = 0
            while accumulator >= STEP and count < 15:
                self.step(now)
                accumulator -= STEP
                count += 1
                if self.tick % 3 == 0:
                    self.broadcast(self.state())
            await asyncio.sleep(max(0.001, STEP-accumulator))

    def message(self, peer, data):
        now = time.monotonic()
        peer.credit = min(90, peer.credit+(now-peer.credit_time)*60)
        peer.credit_time = now
        cost = 15 if data.get('type') == 'chat' else 1
        if peer.credit < cost:
            raise ValueError('Message rate exceeded')
        peer.credit -= cost
        peer.last_seen = now
        if self.hook('on_message', peer, data):
            return
        kind = data.get('type')
        if kind == 'input':
            seq = data.get('seq')
            if type(seq) is not int or not peer.seq < seq <= 2147483647:
                raise ValueError('Input sequence must increase')
            peer.throttle = finite(data.get('throttle', 0), -1, 1)
            peer.steering = finite(data.get('steering', 0), -1, 1)
            peer.seq, peer.last_input = seq, now
        elif kind == 'character' and self.resource.features['characters']:
            value = data.get('value')
            if type(value) is not int or not 0 <= value < 4:
                raise ValueError('Invalid character')
            peer.character = value
        elif kind == 'vehicle' and self.resource.features['vehicles']:
            if type(data.get('driving')) is not bool:
                raise ValueError('Invalid vehicle request')
            peer.driving = data['driving']
        elif kind == 'chat' and self.resource.features['chat']:
            text = data.get('text')
            if not isinstance(text, str) or not 1 <= len(text.strip()) <= 160 or any(ord(c) < 32 for c in text):
                raise ValueError('Invalid chat')
            self.broadcast(dict(type='chat', id=peer.id, name=peer.name, text=text.strip()))
        elif kind not in ('ping', 'character', 'vehicle', 'chat'):
            raise ValueError('Unknown message')

    async def http(self, writer, status, body, kind='text/plain'):
        writer.write(('HTTP/1.1 '+status+'\r\nContent-Type: '+kind+'\r\nContent-Length: '+str(len(body))+'\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n').encode()+body)
        await asyncio.wait_for(writer.drain(), 10)

    async def handle(self, reader, writer):
        self.connections += 1
        peer = None
        try:
            if self.connections > 64:
                return
            raw = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 5)
            lines = raw.decode('ascii').split('\r\n')
            method, target, version = lines[0].split(' ')
            headers = {}
            for line in lines[1:]:
                if line:
                    key, value = line.split(':', 1)
                    if key.lower() in headers:
                        raise ValueError('Duplicate header')
                    headers[key.lower()] = value.strip()
            if method != 'GET' or version != 'HTTP/1.1':
                return await self.http(writer, '405 Method Not Allowed', b'GET required')
            path = target.split('?', 1)[0]
            if path != '/ws':
                if path == '/info':
                    return await self.http(writer, '200 OK', encode(dict(protocol=1, players=len(self.peers), maxPlayers=self.max_players, map=self.resource.public())), 'application/json')
                if path in ('/', '/play.js', '/play.css'):
                    file = ROOT/'client'/('play.html' if path == '/' else path[1:])
                elif path.startswith('/maps/'):
                    file = confined(self.maps, path[len('/maps/'):])
                    if file.suffix.lower() not in ('.json', '.glb', '.bin', '.png', '.jpg', '.jpeg', '.webp', '.vert', '.frag', '.glsl', '.js'):
                        return await self.http(writer, '404 Not Found', b'Not a client resource')
                else:
                    return await self.http(writer, '404 Not Found', b'Not found')
                if not file.is_file() or file.stat().st_size > 256*1024*1024:
                    return await self.http(writer, '404 Not Found', b'Not found')
                # Stream large map assets instead of holding them all in server RAM.
                kind = mimetypes.guess_type(str(file))[0] or 'application/octet-stream'
                writer.write(('HTTP/1.1 200 OK\r\nContent-Type: '+kind+'\r\nContent-Length: '+str(file.stat().st_size)+'\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n').encode())
                with file.open('rb') as stream:
                    while True:
                        chunk = stream.read(65536)
                        if not chunk:
                            break
                        writer.write(chunk)
                        await asyncio.wait_for(writer.drain(), 10)
                return
            key = headers.get('sec-websocket-key', '')
            if headers.get('upgrade', '').lower() != 'websocket' or 'upgrade' not in [v.strip() for v in headers.get('connection', '').lower().split(',')] or headers.get('sec-websocket-version') != '13' or len(base64.b64decode(key, validate=True)) != 16:
                raise ValueError('Invalid WebSocket handshake')
            accept = base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
            writer.write(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+'\r\n\r\n').encode())
            await writer.drain()
            opcode, payload = await asyncio.wait_for(read_frame(reader), 5)
            data = json.loads(payload.decode('utf-8'))
            if opcode != 1 or not isinstance(data, dict) or data.get('type') != 'join' or data.get('protocol') != 1:
                raise ValueError('Expected join protocol 1')
            if self.token and not hmac.compare_digest(str(data.get('token', '')), self.token):
                writer.write(frame(encode(dict(type='error', message='Access token refused'))))
                await writer.drain()
                return
            name = data.get('name', '')
            if not isinstance(name, str) or not 1 <= len(name.strip()) <= 24 or any(ord(c) < 32 for c in name):
                raise ValueError('Invalid player name')
            if len(self.peers) >= self.max_players:
                raise ValueError('Server full')
            peer = Peer(writer, name.strip())
            self.spawn(peer, len(self.peers))
            self.peers[peer.id] = peer
            self.hook('on_join', peer)
            peer.send(dict(type='welcome', protocol=1, id=peer.id, tickRate=60, snapshotRate=20))
            peer.send(self.world())
            self.broadcast(self.state())
            while True:
                opcode, payload = await asyncio.wait_for(read_frame(reader), 15)
                if opcode == 8:
                    writer.write(frame(payload, 8))
                    break
                if opcode == 9:
                    writer.write(frame(payload, 10))
                    continue
                if opcode == 10:
                    continue
                data = json.loads(payload.decode('utf-8'))
                if not isinstance(data, dict):
                    raise ValueError('Expected object')
                self.message(peer, data)
        except (ValueError, OSError, UnicodeError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError, KeyError):
            pass
        finally:
            if peer is not None:
                self.peers.pop(peer.id, None)
                self.hook('on_leave', peer)
                self.broadcast(self.state())
            self.connections -= 1
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass


async def main(args):
    server = await SixmServer(args.host, args.port, args.maps, args.map, os.environ.get('SIXM_SERVER_TOKEN', ''), args.max_players).start()
    print(json.dumps(dict(status='listening', host=args.host, port=server.port, map=server.resource.identifier)), flush=True)
    if args.open:
        webbrowser.open('http://127.0.0.1:'+str(server.port))
    print('Console: maps | map <id> | feature <chat|vehicles|characters> <on|off> | players | quit', flush=True)
    try:
        if args.no_console:
            await asyncio.Future()
        while not args.no_console:
            line = await asyncio.get_running_loop().run_in_executor(None, input, 'sixm> ')
            words = line.strip().split()
            try:
                if words == ['quit']:
                    break
                if words == ['maps']:
                    print(' '.join(p.name for p in server.maps.iterdir() if (p/'map.json').is_file()))
                elif len(words) == 2 and words[0] == 'map':
                    server.change_map(words[1]);print('Map changed:', server.resource.name)
                elif len(words) == 3 and words[0] == 'feature' and words[2] in ('on', 'off'):
                    server.feature(words[1], words[2] == 'on');print('Feature updated')
                elif words == ['players']:
                    print(json.dumps([p.public() for p in server.peers.values()]))
                elif words and words[0] in server.commands:
                    print(server.commands[words[0]](words[1:]))
            except (ValueError, OSError, json.JSONDecodeError) as error:
                print('Command refused:', error)
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        await server.stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=6020)
    parser.add_argument('--maps', type=Path, default=ROOT/'maps')
    parser.add_argument('--map', default='coast')
    parser.add_argument('--max-players', type=int, default=16)
    parser.add_argument('--open', action='store_true')
    parser.add_argument('--no-console', action='store_true')
    options = parser.parse_args()
    if not 0 <= options.port <= 65535 or not 1 <= options.max_players <= 32:
        parser.error('Use a valid port and 1–32 players')
    try:
        asyncio.run(main(options))
    except KeyboardInterrupt:
        pass
