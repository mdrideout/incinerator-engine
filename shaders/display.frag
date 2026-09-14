#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;
layout(set = 2, binding = 0) uniform sampler2D scene_texture;
layout(set = 2, binding = 1) uniform sampler2D bloom_texture;
layout(set = 3, binding = 0) uniform Settings { vec4 values; } settings;
void main() {
    vec3 color = max(texture(scene_texture, uv).rgb + settings.values.x * texture(bloom_texture, uv).rgb, vec3(0.0));
    // Reinhard per-channel shoulder: finite HDR into SDR without hard clipping.
    color = color / (vec3(1.0) + color);
    vec3 encoded = mix(12.92 * color, 1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055, greaterThan(color, vec3(0.0031308)));
    out_color = vec4(encoded, 1.0);
}
