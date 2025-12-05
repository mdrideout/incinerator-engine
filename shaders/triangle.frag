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

// ---------------------------------------------------------------------------
// OUTPUT: Final pixel color
// ---------------------------------------------------------------------------
layout(location = 0) out vec4 out_color;

// ---------------------------------------------------------------------------
// Main entry point - runs once per pixel
// ---------------------------------------------------------------------------
void main() {
    // Output the interpolated color with full opacity (alpha = 1.0)
    out_color = vec4(frag_color, 1.0);
}
