"""Exercise the actual packaged Windows EXEs on the Windows build runner."""
import asyncio
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'multiplayer/tests'))
from test_server import Client


async def check(port):
    a = await Client().connect(port, 'Packaged One')
    b = await Client().connect(port, 'Packaged Two')
    try:
        state = await a.until(lambda d:d.get('type') == 'state' and len(d['players']) == 2)
        assert len({p['id'] for p in state['players']}) == 2
        await b.send(dict(type='chat', text='packaged executable test'))
        await a.until(lambda d:d.get('type') == 'chat' and d.get('text') == 'packaged executable test')
    finally:
        await a.close()
        await b.close()


if __name__ == '__main__':
    client = ROOT/'build/windows/Sixm.exe'
    server = ROOT/'build/windows/SixmServer.exe'
    subprocess.run([str(client), '--check-url', 'http://127.0.0.1:6020'], check=True, timeout=30)
    process = subprocess.Popen([str(server), '--port', '0', '--no-console'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    try:
        line = process.stdout.readline()
        status = json.loads(line)
        port = status['port']
        with urllib.request.urlopen('http://127.0.0.1:'+str(port)+'/play.js', timeout=10) as response:
            assert response.status == 200 and len(response.read()) > 10000
        asyncio.run(check(port))
        print('PASS packaged Windows client, server, bundled resources and two-player chat')
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
