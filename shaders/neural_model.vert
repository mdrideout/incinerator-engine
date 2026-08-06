#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_texcoord;

layout(set = 1, binding = 0) uniform NeuralVertexUniforms {
    mat4 current_mvp;
    mat4 previous_mvp;
    mat4 model;
    mat4 normal_matrix;
    mat4 model_view;
} uniforms;

layout(location = 0) out vec3 frag_color;
layout(location = 1) out vec3 frag_world_position;
layout(location = 2) out vec3 frag_world_normal;
layout(location = 3) out vec4 frag_current_clip;
layout(location = 4) out vec4 frag_previous_clip;
layout(location = 5) out float frag_view_depth;
layout(location = 6) out vec2 frag_texcoord;

void main() {
    vec4 local = vec4(in_position, 1.0);
    frag_color = vec3(1.0);
    frag_world_position = (uniforms.model * local).xyz;
    frag_world_normal = normalize((uniforms.normal_matrix * vec4(in_normal, 0.0)).xyz);
    frag_current_clip = uniforms.current_mvp * local;
    frag_previous_clip = uniforms.previous_mvp * local;
    frag_view_depth = -(uniforms.model_view * local).z;
    frag_texcoord = in_texcoord;
    gl_Position = frag_current_clip;
}
