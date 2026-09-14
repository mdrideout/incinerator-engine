#version 450
layout(location = 0) in vec2 uv;
layout(location = 0) out vec4 out_color;
layout(set = 2, binding = 0) uniform sampler2D source_texture;
layout(set = 3, binding = 0) uniform Settings { vec4 values; } settings;
void main() {
    vec2 step_uv = settings.values.xy;
    // Bilinear tent taps: the pyramid supplies a broad halo at reduced size.
    vec3 result = texture(source_texture, uv).rgb * 4.0;
    result += (texture(source_texture, uv + vec2(step_uv.x, 0)).rgb + texture(source_texture, uv - vec2(step_uv.x, 0)).rgb
             + texture(source_texture, uv + vec2(0, step_uv.y)).rgb + texture(source_texture, uv - vec2(0, step_uv.y)).rgb) * 2.0;
    result += texture(source_texture, uv + step_uv).rgb + texture(source_texture, uv - step_uv).rgb
            + texture(source_texture, uv + vec2(step_uv.x, -step_uv.y)).rgb + texture(source_texture, uv + vec2(-step_uv.x, step_uv.y)).rgb;
    result /= 16.0;
    if (settings.values.w > 0.5) {
        float brightness = max(result.r, max(result.g, result.b));
        result *= max(brightness - settings.values.z, 0.0) / max(brightness, 1e-8);
    }
    out_color = vec4(result, 1.0);
}
