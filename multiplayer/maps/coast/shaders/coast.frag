#version 300 es
precision highp float;in vec3 n;in vec2 texCoord;uniform vec4 color;uniform sampler2D baseTexture;uniform bool textured;out vec4 outColor;void main(){vec4 base=color*(textured?texture(baseTexture,texCoord):vec4(1.0));float light=0.35+0.65*max(dot(normalize(n),normalize(vec3(-0.4,1.0,-0.3))),0.0);outColor=vec4(pow(max(base.rgb*light,vec3(0.0)),vec3(1.0/2.2)),base.a);}
