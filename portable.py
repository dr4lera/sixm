#!/usr/bin/env python3
"""Sixm Windows/macOS launcher and read-only local dump inspector. Python 3.9+."""
import argparse
import http.server
import json
import pathlib
import secrets
import struct
import threading
import urllib.parse
import webbrowser


def inspect(root):
    root = pathlib.Path(root).expanduser().resolve(strict=True)
    if not root.is_dir():
        raise ValueError('Choose the extracted Xbox dump folder.')
    archives, warnings = [], []
    count = total = sources = 0
    executable = pe = False
    for item in root.rglob('*'):
        if any(part.startswith('.') for part in item.relative_to(root).parts) or item.is_symlink() or not item.is_file():
            continue
        count += 1
        if count > 200000:
            raise ValueError('Folder exceeds the 200,000-file inspection limit.')
        size = item.stat().st_size
        total += size
        sources += item.suffix.lower() in {'.c','.cpp','.h','.hpp','.cs','.sln'}
        if item.name == 'game_scarlett_master.exe':
            executable = True
            with item.open('rb') as stream:
                header = stream.read(64)
                if len(header) == 64 and header[:2] == b'MZ':
                    offset, = struct.unpack_from('<I', header, 60)
                    if offset <= size-4:
                        stream.seek(offset)
                        pe = stream.read(4) == b'PE\0\0'
        if item.suffix.lower() == '.rpf':
            with item.open('rb') as stream:
                header = stream.read(32)
            magic = {b'9FPR':'RPF9',b'7FPR':'RPF7'}.get(header[:4],'Unknown')
            archives.append(dict(path=item.relative_to(root).as_posix(), bytes=size, magic=magic, headerHex=header.hex()))
            if len(header) < 32:
                warnings.append('Truncated archive header: '+item.name)
    if not pe:
        warnings.append('Valid Xbox PE executable not found.')
    if not sources:
        warnings.append('No recovered C/C++/C# source files found in this folder.')
    warnings.append('Header inventory only. Extraction and game asset conversion are not implemented in this launcher.')
    return dict(root=str(root), fileCount=count,totalBytes=total,sourceFileCount=sources,
                executablePresent=executable,executableIsPE=pe,archives=sorted(archives,key=lambda a:a['path']),
                warnings=warnings,extractedAssetCount=0,formatSupport='Header inventory only')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inspect', metavar='DUMP')
    parser.add_argument('--no-browser', action='store_true')
    args = parser.parse_args()
    if args.inspect:
        print(json.dumps(inspect(args.inspect),indent=2))
        return
    html = pathlib.Path(__file__).with_name('index.html').read_text(encoding='utf-8')
    token = secrets.token_urlsafe(32)
    bridge = '''<script>
    window.send = async function(action, extra={}) {
      if(action==='recover'||action==='cancelImport'){alert('Automated model conversion currently requires the native Mac build with SixNG bundled. Windows launcher inspection is available.');return;}
      if(action==='model'){alert('Static GLB preview currently requires the native Mac app. Windows rendering is not implemented yet.');return;}
      if(action==='sandbox'){alert('This renderer test currently requires the native Mac app. Windows gameplay is not implemented yet.');return;}
      if(action==='import'){const path=prompt('Path to your extracted Xbox dump folder:');if(!path)return;extra={path};action='inspect';}
      try{window.receive({type:'scanning'});const response=await fetch('/api',{method:'POST',headers:{'Content-Type':'application/json','X-Sixm-Token':TOKEN},body:JSON.stringify({action,...extra})});window.receive(await response.json());}
      catch(e){window.receive({type:'error',message:String(e)});}
    };
    </script>'''.replace('TOKEN',json.dumps(token))
    html = html.replace('</html>',bridge+'</html>').encode()
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass
        def reply(self, code, payload, kind='application/json'):
            if not isinstance(payload, bytes):
                payload = json.dumps(payload).encode()
            self.send_response(code)
            self.send_header('Content-Type',kind)
            self.send_header('Content-Length',str(len(payload)))
            self.send_header('Cache-Control','no-store')
            self.send_header('X-Content-Type-Options','nosniff')
            self.end_headers()
            self.wfile.write(payload)
        def do_GET(self):
            expected = f'127.0.0.1:{self.server.server_port}'
            if self.headers.get('Host') != expected:
                return self.reply(403,{'error':'Host refused'})
            if urllib.parse.urlsplit(self.path).path != '/':
                return self.reply(404,{'error':'Not found'})
            self.reply(200,html,'text/html; charset=utf-8')
        def do_POST(self):
            expected = f'127.0.0.1:{self.server.server_port}'
            origin = self.headers.get('Origin')
            if self.path != '/api' or self.headers.get('Host') != expected or self.headers.get('X-Sixm-Token') != token or origin not in (None,'http://'+expected):
                return self.reply(403,{'type':'error','message':'Request refused'})
            try:
                length = int(self.headers.get('Content-Length','0'))
                if not 0 < length <= 8192:
                    raise ValueError('Invalid request length')
                request = json.loads(self.rfile.read(length))
                if request.get('action') != 'inspect':
                    raise ValueError('Unknown action')
                self.reply(200,{'type':'inventory','data':inspect(request['path'])})
            except (OSError,ValueError,KeyError,TypeError) as error:
                self.reply(400,{'type':'error','message':str(error)})
    server = http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler)
    url = 'http://127.0.0.1:'+str(server.server_port)+'/'
    print('Sixm launcher: '+url,flush=True)
    print('Local launcher/inspector only. Press Ctrl+C to stop.',flush=True)
    if not args.no_browser:
        threading.Timer(.2,lambda:webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()

if __name__ == '__main__':
    main()
