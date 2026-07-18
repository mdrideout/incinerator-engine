#version 450

// Validation-only semantic visibility output. Attachment zero is a stable
// object ID; attachment one is a compact selected-entity color preview for
// first-failure artifacts. Both use normalized RGBA8 targets.
layout(set = 3, binding = 0) uniform VisibilitySettings {
    vec4 id_color;
    vec4 display_color;
} settings;

layout(location = 0) out vec4 out_id;
layout(location = 1) out vec4 out_color;

void main() {
    out_id = settings.id_color;
    out_color = settings.display_color;
}
