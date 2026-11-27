// Client resources can subscribe to messages, draw through WebGL and add UI.
const stop = Sixm.on('coast:reply', event => Sixm.log(event.text));
Sixm.on('unload', stop);
Sixm.send({type:'coast:hello'});
