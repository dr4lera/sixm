#version 300 es
precision highp float;layout(location=0)in vec3 position;layout(location=1)in vec3 normal;layout(location=2)in vec2 uv;uniform mat4 model;uniform mat4 viewProjection;out vec3 n;out vec2 texCoord;void main(){n=mat3(transpose(inverse(model)))*normal;texCoord=uv;gl_Position=viewProjection*model*vec4(position,1.0);}
