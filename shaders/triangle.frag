#version 450

// ============================================================================
// triangle.frag - Fragment Shader for colored triangle
// ============================================================================
//
// This shader runs once per pixel (fragment). It receives interpolated data
// from the vertex shader and outputs the final color for that pixel.
//
// Compilation: glslc triangle.frag -o triangle.frag.spv

// ---------------------------------------------------------------------------
// INPUT: Interpolated data from vertex shader
// ---------------------------------------------------------------------------
// The GPU automatically interpolates vertex outputs across the triangle face.
// So a pixel in the middle of a red-green-blue triangle gets a blended color.
layout(location = 0) in vec3 frag_color;

// Primitive meshes retain their authored vertex-color detail while accepting
// the same material tint promised by Renderer.drawMeshWithMaterial.
layout(set = 3, binding = 0) uniform PrimitiveFragmentSettings {
    vec4 base_color;
} settings;

// ---------------------------------------------------------------------------
// OUTPUT: Final pixel color
// ---------------------------------------------------------------------------
layout(location = 0) out vec4 out_color;

// ---------------------------------------------------------------------------
// Main entry point - runs once per pixel
// ---------------------------------------------------------------------------
void main() {
    out_color = vec4(frag_color * settings.base_color.rgb, settings.base_color.a);
}
