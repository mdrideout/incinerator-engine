#version 450

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_color;

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

void main() {
    vec4 local = vec4(in_position, 1.0);
    frag_color = in_color;
    frag_world_position = (uniforms.model * local).xyz;
    frag_world_normal = vec3(0.0);
    frag_current_clip = uniforms.current_mvp * local;
    frag_previous_clip = uniforms.previous_mvp * local;
    frag_view_depth = -(uniforms.model_view * local).z;
    gl_Position = frag_current_clip;
}
