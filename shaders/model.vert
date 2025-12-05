#version 450

// =============================================================================
// Model Vertex Shader
// =============================================================================
// For loaded 3D models (GLB/glTF). Expects VertexPNU format from mesh.zig.
//
// Vertex data layout (32 bytes per vertex):
//   position: [0..11]   - 3 floats (vec3)
//   normal:   [12..23]  - 3 floats (vec3)
//   texcoord: [24..31]  - 2 floats (vec2)

// Vertex inputs (must match VertexPNU in mesh.zig)
layout(location = 0) in vec3 in_position;  // Object-space position
layout(location = 1) in vec3 in_normal;    // Surface normal (for lighting)
layout(location = 2) in vec2 in_texcoord;  // Texture coordinates

// Outputs to fragment shader
layout(location = 0) out vec3 frag_normal;
layout(location = 1) out vec2 frag_texcoord;

// Uniform buffer (slot 0 in set 1, same convention as triangle.vert)
layout(set = 1, binding = 0) uniform Uniforms {
    mat4 mvp;  // Model-View-Projection matrix
};

void main() {
    // Transform vertex position from object space to clip space
    gl_Position = mvp * vec4(in_position, 1.0);

    // Pass normal and UV to fragment shader
    // Note: For correct lighting with non-uniform scaling, normal should be
    // transformed by inverse-transpose of model matrix. For now, we pass
    // it directly (works correctly for uniform scaling and rotation).
    frag_normal = in_normal;
    frag_texcoord = in_texcoord;
}
