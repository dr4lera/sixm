import asyncio
import base64
import json
from pathlib import Path
import secrets
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from server import SixmServer, encode, MapResource, ROOT


class Client:
    async def connect(self, port, name='Test', token=''):
        self.reader, self.writer = await asyncio.open_connection('127.0.0.1', port)
        key = base64.b64encode(secrets.token_bytes(16)).decode()
        self.writer.write(('GET /ws HTTP/1.1\r\nHost: 127.0.0.1:'+str(port)+'\r\nUpgrade: websocket\r\nConnection: keep-alive,Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: '+key+'\r\n\r\n').encode())
        await self.writer.drain()
        assert b'101 Switching Protocols' in await self.reader.readuntil(b'\r\n\r\n')
        await self.send(dict(type='join', protocol=1, name=name, token=token))
        return self

    async def send(self, value):
        payload = encode(value)
        mask = secrets.token_bytes(4)
        header = bytes([0x81, 0x80 | len(payload)]) if len(payload) < 126 else b'\x81\xfe'+struct.pack('!H', len(payload))
        self.writer.write(header+mask+bytes(x ^ mask[i % 4] for i, x in enumerate(payload)))
        await self.writer.drain()

    async def receive(self):
        a, b = await asyncio.wait_for(self.reader.readexactly(2), 2)
        n = b & 127
        if n == 126:
            n, = struct.unpack('!H', await self.reader.readexactly(2))
        elif n == 127:
            n, = struct.unpack('!Q', await self.reader.readexactly(8))
        return json.loads((await self.reader.readexactly(n)).decode())

    async def until(self, predicate):
        for _ in range(100):
            data = await self.receive()
            if predicate(data):
                return data
        raise AssertionError('Expected message not received')

    async def close(self):
        self.writer.close()
        await self.writer.wait_closed()


class ServerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.server = await SixmServer(port=0).start()
        self.clients = []

    async def asyncTearDown(self):
        for client in self.clients:
            await client.close()
        await self.server.stop()

    async def client(self, name):
        client = await Client().connect(self.server.port, name)
        self.clients.append(client)
        welcome = await client.until(lambda d:d.get('type') == 'welcome')
        return client, welcome['id']

    async def test_two_clients_authority_features_and_map_switch(self):
        a, aid = await self.client('One')
        b, bid = await self.client('Two')
        state = await a.until(lambda d:d.get('type') == 'state' and len(d['players']) == 2)
        self.assertNotEqual(aid, bid)
        start = next(p for p in state['players'] if p['id'] == aid)
        await a.send(dict(type='input', seq=1, throttle=1, steering=0, x=999999))
        await asyncio.sleep(.2)
        state = await b.until(lambda d:d.get('type') == 'state' and any(p['id'] == aid and p['seq'] == 1 and p['z'] > start['z']+.05 for p in d['players']))
        moved = next(p for p in state['players'] if p['id'] == aid)
        self.assertLess(moved['z']-start['z'], 2)
        self.assertEqual(moved['x'], start['x'])
        await a.send(dict(type='character', value=2))
        await b.send(dict(type='chat', text='Shared message'))
        chat = await a.until(lambda d:d.get('type') == 'chat' and d.get('text') == 'Shared message')
        self.assertEqual(chat['name'], 'Two')
        await a.send(dict(type='coast:hello'))
        await a.until(lambda d:d.get('type') == 'coast:reply')
        self.server.feature('vehicles', False)
        await a.send(dict(type='vehicle', driving=True))
        state = await b.until(lambda d:d.get('type') == 'state' and d['revision'] == 2)
        self.assertFalse(next(p for p in state['players'] if p['id'] == aid)['driving'])
        self.server.change_map('courtyard')
        world = await a.until(lambda d:d.get('type') == 'world' and d['revision'] == 3)
        self.assertEqual(world['map']['id'], 'courtyard')
        state = await b.until(lambda d:d.get('type') == 'state' and d['revision'] == 3)
        player = next(p for p in state['players'] if p['id'] == aid)
        self.assertEqual([player['x'],player['y'],player['z']], [0,0,0])
        self.assertNotIn('announce', self.server.commands)

    async def test_invalid_numeric_input_disconnects(self):
        client, _ = await self.client('Invalid')
        # Position cannot be supplied by clients, nor can non-finite movement.
        await client.send(dict(type='input', seq=1, throttle='NaN', steering=0))
        for _ in range(30):
            if not self.server.peers:
                break
            await asyncio.sleep(.01)
        self.assertFalse(self.server.peers)

    async def test_authentication_and_resource_paths(self):
        self.server.token = 'test-access-token'
        bad = await Client().connect(self.server.port, token='wrong')
        self.clients.append(bad)
        result = await bad.receive()
        self.assertEqual(result['type'], 'error')
        self.assertFalse(self.server.peers)
        with self.assertRaises(ValueError):
            self.server.change_map('../outside')
        self.assertEqual(self.server.resource.identifier, 'coast')
        reader, writer = await asyncio.open_connection('127.0.0.1', self.server.port)
        writer.write(b'GET /maps/coast/resources/welcome.py HTTP/1.1\r\nHost: localhost\r\n\r\n')
        await writer.drain()
        self.assertIn(b'404 Not Found', await reader.read())
        writer.close()
        await writer.wait_closed()

    async def test_collision_and_stale_input(self):
        client, identifier = await self.client('Collision')
        peer = self.server.peers[identifier]
        peer.x, peer.z, peer.throttle, peer.speed = 0, 16.65, 1, 5
        for _ in range(30):
            self.server.step(peer.last_input)
        self.assertLess(peer.z, 16.7)  # Barrier starts at z=17, player radius .3.
        peer.z, peer.speed, peer.throttle = 0, 0, 1
        self.server.step(peer.last_input+1)
        self.assertEqual(peer.speed, 0)


if __name__ == '__main__':
    unittest.main()
