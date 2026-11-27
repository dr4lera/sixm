#!/usr/bin/env python3
"""Open a Sixm server's browser client on Windows or macOS."""
import argparse
import urllib.parse
import webbrowser

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url', nargs='?')
    parser.add_argument('--check-url', action='store_true', help='Validate the URL without opening a browser.')
    args = parser.parse_args()
    address = args.url or input('Server HTTP URL [http://127.0.0.1:6022]: ').strip() or 'http://127.0.0.1:6022'
    url = urllib.parse.urlsplit(address)
    if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password:
        parser.error('Enter an HTTP or HTTPS server URL, without credentials.')
    if args.check_url:
        print('URL_OK '+address)
    else:
        webbrowser.open(address)
