#version 450

// =============================================================================
// Model Fragment Shader
// =============================================================================
// For loaded 3D models (GLB/glTF). Receives interpolated normal and UV.
// Samples diffuse texture and applies basic lighting.

// Inputs from vertex shader (normal is in world space)
layout(location = 0) in vec3 frag_normal;
layout(location = 1) in vec2 frag_texcoord;

// Fragment settings uniform buffer
layout(set = 3, binding = 0) uniform FragmentSettings {
    float use_texture; // 1.0 = use texture, 0.0 = use white
    float _padding1;
    float _padding2;
    float _padding3;
} settings;

// Texture sampler (bound at slot 0)
layout(set = 2, binding = 0) uniform sampler2D diffuse_texture;

// Output color
layout(location = 0) out vec4 out_color;

void main() {
    // Sample the diffuse texture or use white based on settings
    vec4 tex_color;
    if (settings.use_texture > 0.5) {
        tex_color = texture(diffuse_texture, frag_texcoord);
    } else {
        tex_color = vec4(1.0, 1.0, 1.0, 1.0);
    }

    // Normalize the interpolated normal (interpolation can denormalize it)
    vec3 normal = normalize(frag_normal);

    // Simple world-space directional light from above-right-front
    vec3 light_dir = normalize(vec3(0.5, 1.0, 0.3));
    float ndotl = max(dot(normal, light_dir), 0.0);

    // Ambient + diffuse lighting
    float ambient = 0.3;
    float diffuse = 0.7 * ndotl;
    float lighting = ambient + diffuse;

    // Apply lighting to texture color
    out_color = vec4(tex_color.rgb * lighting, tex_color.a);
}
