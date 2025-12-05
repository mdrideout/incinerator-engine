#version 450

// ============================================================================
// triangle.vert - Vertex Shader for colored triangle
// ============================================================================
//
// This shader runs once per vertex. It receives vertex attributes from the
// vertex buffer and outputs the final screen position plus any data needed
// by the fragment shader.
//
// Compilation: glslc triangle.vert -o triangle.vert.spv

// ---------------------------------------------------------------------------
// INPUT: Vertex attributes from vertex buffer
// ---------------------------------------------------------------------------
// location = N must match the vertex buffer layout we define in Zig
layout(location = 0) in vec3 in_position;  // Vertex position (x, y, z)
layout(location = 1) in vec3 in_color;     // Vertex color (r, g, b)

// ---------------------------------------------------------------------------
// OUTPUT: Data passed to fragment shader (interpolated across triangle)
// ---------------------------------------------------------------------------
layout(location = 0) out vec3 frag_color;

// ---------------------------------------------------------------------------
// Main entry point - runs once per vertex
// ---------------------------------------------------------------------------
void main() {
    // Pass the vertex color to the fragment shader.
    // The GPU will automatically interpolate this across the triangle face,
    // so pixels between vertices get blended colors.
    frag_color = in_color;

    // Set the vertex position in clip space.
    // gl_Position is a built-in output that MUST be set.
    //
    // Clip space coordinates:
    //   X: -1 (left) to +1 (right)
    //   Y: -1 (bottom) to +1 (top)
    //   Z: 0 (near) to 1 (far)
    //   W: 1.0 for standard positions
    //
    // Later we'll multiply by a Model-View-Projection matrix here.
    // For now, we pass through directly (identity transform).
    gl_Position = vec4(in_position, 1.0);
}
