#version 450

// ============================================================================
// triangle.vert - Vertex Shader with MVP transform
// ============================================================================
//
// This shader transforms vertices from local object space to clip space
// using the Model-View-Projection (MVP) matrix pipeline.
//
// Compilation: glslc triangle.vert -o triangle.vert.spv

// ---------------------------------------------------------------------------
// UNIFORM BUFFER: Shared data from CPU (updated per-object)
// ---------------------------------------------------------------------------
// set = 0: First descriptor set
// binding = 0: First binding within that set
layout(set = 0, binding = 0) uniform Uniforms {
    mat4 mvp;  // Model-View-Projection matrix (combined)
};

// ---------------------------------------------------------------------------
// INPUT: Vertex attributes from vertex buffer
// ---------------------------------------------------------------------------
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
    // The GPU will automatically interpolate this across the triangle face.
    frag_color = in_color;

    // Transform vertex position through the MVP pipeline:
    //   1. Model matrix: object space → world space
    //   2. View matrix: world space → camera space
    //   3. Projection matrix: camera space → clip space
    //
    // These are pre-multiplied on the CPU into a single MVP matrix.
    gl_Position = mvp * vec4(in_position, 1.0);
}
