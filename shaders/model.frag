#version 450

layout(location = 0) in vec3 frag_normal;
layout(location = 1) in vec2 frag_texcoord;
layout(location = 2) in vec3 frag_position;

layout(set = 3, binding = 0) uniform FragmentSettings {
    float use_texture;
    float lit;
    uint texture_mask;
    float _padding;
    vec4 base_color;
    vec4 emissive;
    vec4 sun_direction;
    vec4 sun_color_intensity;
    vec4 ambient_color;
    vec4 response; // metallic, roughness, normal scale, occlusion strength
    vec4 camera_position;
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

// SDL's product target uses UNORM storage. Color maps are decoded from sRGB
// by the sampler; encode the shaded linear result exactly once for display.
vec3 displayColor(vec3 linear) {
    linear = max(linear, vec3(0.0));
    return mix(12.92 * linear, 1.055 * pow(linear, vec3(1.0 / 2.4)) - 0.055,
        greaterThan(linear, vec3(0.0031308)));
}

vec3 surfaceNormal() {
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
}

void main() {
    vec4 color = settings.base_color;
    if (hasMap(1u)) color *= texture(base_color_texture, frag_texcoord);
    vec3 emission = settings.emissive.rgb;
    if (hasMap(16u)) emission *= texture(emissive_texture, frag_texcoord).rgb;
    if (settings.lit < 0.5) {
        out_color = vec4(displayColor(color.rgb + emission), color.a);
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
    vec3 h = normalize(v + l);
    float nl = max(dot(n, l), 0.0);
    float nv = max(dot(n, v), 1e-5);
    float nh = max(dot(n, h), 0.0);
    float vh = max(dot(v, h), 0.0);
    vec3 f0 = mix(vec3(0.04), color.rgb, metallic);
    vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
    // Numerical regularization at the perfectly smooth endpoint only;
    // authored roughness retains its full [0,1] domain.
    float alpha = max(roughness * roughness, 0.001);
    float a2 = alpha * alpha;
    float dbase = nh * nh * (a2 - 1.0) + 1.0;
    float distribution = a2 / (3.14159265 * dbase * dbase);
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float visibility = 0.5 / max(gv + gl, 1e-5);
    vec3 diffuse = (1.0 - fresnel) * (1.0 - metallic) * color.rgb / 3.14159265;
    vec3 direct = (diffuse + fresnel * distribution * visibility) *
        settings.sun_color_intensity.rgb * settings.sun_color_intensity.a * nl;
    // Ambient diffuse is intentionally independent of direct-light occlusion.
    // Reflection probes/environment specular remain a separate lighting capability.
    vec3 indirect = settings.ambient_color.rgb * color.rgb * (1.0 - metallic) * ao;
    out_color = vec4(displayColor(direct + indirect + emission), color.a);
}
