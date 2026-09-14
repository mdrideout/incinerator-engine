#version 450
layout(location=0) in vec3 in_position;
layout(location=1) in vec3 in_color;
layout(location=0) out vec3 frag_normal;
layout(location=1) out vec2 frag_texcoord;
layout(location=2) out vec3 frag_position;
layout(location=3) out vec3 frag_color;
layout(set=1,binding=0) uniform Uniforms { mat4 mvp; mat4 normal_matrix; mat4 model; };
void main() {
    gl_Position = mvp * vec4(in_position,1);
    frag_position = (model * vec4(in_position,1)).xyz;
    frag_normal = vec3(0);
    frag_texcoord = vec2(0);
    frag_color = in_color;
}
