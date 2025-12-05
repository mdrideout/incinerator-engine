#version 450

// =============================================================================
// Model Fragment Shader
// =============================================================================
// For loaded 3D models (GLB/glTF). Receives interpolated normal and UV.
//
// Current implementation: Visualize normals as colors (debug view)
// Future: Sample textures, calculate PBR lighting

// Inputs from vertex shader
layout(location = 0) in vec3 frag_normal;
layout(location = 1) in vec2 frag_texcoord;

// Output color
layout(location = 0) out vec4 out_color;

void main() {
    // Normalize the interpolated normal (interpolation can denormalize it)
    vec3 normal = normalize(frag_normal);

    // Convert normal from [-1,1] range to [0,1] range for visualization
    // This maps: -X=black, +X=red, -Y=black, +Y=green, -Z=black, +Z=blue
    vec3 normal_color = normal * 0.5 + 0.5;

    out_color = vec4(normal_color, 1.0);

    // Future enhancements:
    // - Sample diffuse texture: texture(diffuse_sampler, frag_texcoord)
    // - Basic lighting: dot(normal, light_dir) * light_color
    // - PBR: metallic/roughness workflow
}
