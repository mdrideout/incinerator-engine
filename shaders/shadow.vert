#version 450
layout(location=0) in vec3 in_position;
layout(set=1,binding=0) uniform Transform { mat4 mvp; };
void main() { gl_Position = mvp * vec4(in_position,1); }
