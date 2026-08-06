#version 450

layout(location = 0) in vec3 frag_color;
layout(location = 1) in vec3 frag_world_position;
layout(location = 2) in vec3 frag_world_normal;
layout(location = 3) in vec4 frag_current_clip;
layout(location = 4) in vec4 frag_previous_clip;
layout(location = 5) in float frag_view_depth;

layout(set = 3, binding = 0) uniform NeuralFragmentSettings {
    float use_texture;
    float history_valid;
    float near_plane;
    float far_plane;
    vec4 base_color;
    vec4 semantic_color;
    vec4 instance_color;
} settings;

layout(location = 0) out vec4 out_appearance;
layout(location = 1) out vec4 out_depth;
layout(location = 2) out vec4 out_normal;
layout(location = 3) out vec4 out_motion;
layout(location = 4) out vec4 out_semantic;
layout(location = 5) out vec4 out_instance;

vec3 geometric_normal() {
    // Framebuffer Y grows downward after the GLSL-to-Metal transform. Reverse
    // the derivative order so a +Y world-space floor encodes +Y, not -Y.
    return normalize(cross(dFdy(frag_world_position), dFdx(frag_world_position)));
}

void main() {
    vec3 normal = geometric_normal();
    vec3 light_dir = normalize(vec3(0.5, 1.0, 0.3));
    float lighting = 0.3 + 0.7 * max(dot(normal, light_dir), 0.0);
    vec3 current_ndc = frag_current_clip.xyz / frag_current_clip.w;
    vec3 previous_ndc = frag_previous_clip.xyz / frag_previous_clip.w;
    vec2 encoded_motion = clamp((current_ndc.xy - previous_ndc.xy) * 0.5, -0.5, 0.5) + 0.5;
    float depth = clamp((frag_view_depth - settings.near_plane) /
        (settings.far_plane - settings.near_plane), 0.0, 1.0);
    out_appearance = vec4(frag_color * settings.base_color.rgb * lighting, 1.0);
    out_depth = vec4(depth, depth, depth, 1.0);
    out_normal = vec4(normal * 0.5 + 0.5, 1.0);
    out_motion = vec4(encoded_motion, settings.history_valid, 1.0);
    out_semantic = settings.semantic_color;
    out_instance = settings.instance_color;
}
