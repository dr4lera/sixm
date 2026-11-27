"""Example operator-installed server resource. Has normal Python/server access."""
def on_load(server):
    def announce(words):
        text = ' '.join(words)[:160]
        server.broadcast(dict(type='chat', name='Coast operator', text=text))
        return 'Announcement sent'
    server.register_command('announce', announce)


def on_join(server, peer):
    peer.send(dict(type='chat', name='Coast', text='Welcome. This map uses authored test geometry and debug avatars.'))


def on_message(server, peer, message):
    if message.get('type') == 'coast:hello':
        peer.send(dict(type='coast:reply', text='Server resource received your custom event.'))
        return True
    return False
