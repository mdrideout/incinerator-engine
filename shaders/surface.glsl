#include "lighting.glsl"

#ifdef VERTEX_COLOR
layout(location = 3) in vec3 frag_color;
#endif
layout(location = 0) in vec3 frag_normal;
layout(location = 1) in vec2 frag_texcoord;
layout(location = 2) in vec3 frag_position;

layout(set = 3, binding = 0) uniform FragmentSettings {
    float use_texture;
    float lit;
    uint texture_mask;
    float exposure;
    vec4 base_color;
    vec4 emissive;
    vec4 sun_direction;
    vec4 sun_color_intensity;
    vec4 ambient_color;
    vec4 response; // metallic, roughness, normal scale, occlusion strength
    vec4 camera_position;
    uvec4 lighting;
} settings;

layout(set = 2, binding = 0) uniform sampler2D base_color_texture;
layout(set = 2, binding = 1) uniform sampler2D metallic_roughness_texture;
layout(set = 2, binding = 2) uniform sampler2D normal_texture;
layout(set = 2, binding = 3) uniform sampler2D occlusion_texture;
layout(set = 2, binding = 4) uniform sampler2D emissive_texture;
layout(location = 0) out vec4 out_color;

bool hasMap(uint bit) {
    return settings.use_texture > 0.5 && (settings.texture_mask & bit) != 0u;
}

vec3 surfaceNormal() {
#ifdef VERTEX_COLOR
    // Raster-space Y points down; orient the face normal toward its viewer.
    return -normalize(cross(dFdx(frag_position), dFdy(frag_position)));
#else
    vec3 n = normalize(frag_normal);
    // Derive the tangent frame from this mesh's actual world-space UV
    // derivatives, preserving mirrored UV orientation and nonuniform scale.
    vec3 dpdx = dFdx(frag_position), dpdy = dFdy(frag_position);
    vec2 duvdx = dFdx(frag_texcoord), duvdy = dFdy(frag_texcoord);
    vec3 pdy = cross(dpdy, n), pdx = cross(n, dpdx);
    vec3 t = pdy * duvdx.x + pdx * duvdy.x;
    vec3 b = pdy * duvdx.y + pdx * duvdy.y;
    float length2 = max(dot(t, t), dot(b, b));
    if (!hasMap(4u) || length2 < 1e-12) return n;
    vec3 mapped = texture(normal_texture, frag_texcoord).xyz * 2.0 - 1.0;
    mapped.xy *= settings.response.z;
    float inverse_length = inversesqrt(length2);
    return normalize(mat3(t * inverse_length, b * inverse_length, n) * mapped);
#endif
}

void main() {
    vec4 color = settings.base_color;
#ifdef VERTEX_COLOR
    color.rgb *= frag_color;
#endif
    if (hasMap(1u)) color *= texture(base_color_texture, frag_texcoord);
    vec3 emission = settings.emissive.rgb;
    if (hasMap(16u)) emission *= texture(emissive_texture, frag_texcoord).rgb;
    if (settings.lighting.y != 0u) {
        out_color = vec4(color.rgb + emission, color.a);
        return;
    }
    if (settings.lit < 0.5) {
        out_color = vec4((color.rgb + emission) * settings.exposure, color.a);
        return;
    }

    float metallic = settings.response.x;
    float roughness = settings.response.y;
    if (hasMap(2u)) {
        vec4 mr = texture(metallic_roughness_texture, frag_texcoord);
        metallic *= mr.b;
        roughness *= mr.g;
    }
    float ao = hasMap(8u) ? mix(1.0, texture(occlusion_texture, frag_texcoord).r, settings.response.w) : 1.0;
    vec3 n = surfaceNormal();
    vec3 v = normalize(settings.camera_position.xyz - frag_position);
    vec3 l = normalize(settings.sun_direction.xyz);
    vec3 direct = directResponse(color.rgb, metallic, roughness, n, v, l,
        settings.sun_color_intensity.rgb * settings.sun_color_intensity.a);
    direct += localResponse(settings.lighting.x, frag_position, color.rgb, metallic, roughness, n, v);
    // Ambient diffuse is intentionally independent of direct-light occlusion.
    // Reflection probes/environment specular remain a separate lighting capability.
    vec3 indirect = settings.ambient_color.rgb * color.rgb * (1.0 - metallic) * ao;
    out_color = vec4((direct + indirect + emission) * settings.exposure, color.a);
}
