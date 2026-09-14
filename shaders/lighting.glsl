// MSL product ABI: buffer(0) is the fragment uniform, buffer(1) is light data.
// Set 4 separates these explicit Metal buffer indices from sampled textures in
// the intermediate SPIR-V. That intermediate is not an SDL Vulkan artifact.
struct LocalLight {
    vec4 position_range;
    vec4 color_intensity;
    vec4 direction_outer;
    vec4 parameters;
};
layout(std140, set = 4, binding = 1) readonly buffer LightBuffer { LocalLight lights[]; } light_buffer;

struct ShadowView { mat4 matrix; vec4 parameters; };
layout(std140,set=4,binding=2) readonly buffer ShadowBuffer { ShadowView views[]; } shadow_buffer;
layout(set=2,binding=5) uniform sampler2DArrayShadow shadow_maps;
float shadowVisibility(LocalLight light, vec3 position) {
    if (light.parameters.w < 0.0) return 1.0;
    uint layer = uint(light.parameters.w);
    if (light.parameters.z > 0.5 && (light.parameters.z < 1.5 || light.direction_outer.w <= 0.0)) {
        vec3 d = position - light.position_range.xyz;
        vec3 a = abs(d);
        if (a.x >= a.y && a.x >= a.z) layer += d.x >= 0.0 ? 0u : 1u;
        else if (a.y >= a.z) layer += d.y >= 0.0 ? 2u : 3u;
        else layer += d.z >= 0.0 ? 4u : 5u;
    }
    ShadowView view = shadow_buffer.views[layer];
    vec4 clip = view.matrix * vec4(position,1);
    if (clip.w <= 0.0) return 1.0;
    vec3 p = clip.xyz / clip.w;
    if (p.z < 0.0 || p.z > 1.0 || abs(p.x) > 1.0 || abs(p.y) > 1.0) return 1.0;
    vec2 uv = vec2(p.x*0.5+0.5, 0.5-p.y*0.5);
    float sum = 0.0;
    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x)
        sum += texture(shadow_maps, vec4(uv + vec2(x,y)*view.parameters.y, float(layer), p.z-view.parameters.x));
    return sum/9.0;
}

vec3 directResponse(vec3 color, float metallic, float roughness, vec3 n, vec3 v, vec3 l, vec3 energy) {
    float nl = max(dot(n, l), 0.0);
    if (nl <= 0.0) return vec3(0);
    vec3 h = normalize(v + l);
    float nv = max(dot(n, v), 1e-5);
    float nh = max(dot(n, h), 0.0);
    float vh = max(dot(v, h), 0.0);
    vec3 f0 = mix(vec3(0.04), color, metallic);
    vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vh, 5.0);
    float alpha = max(roughness * roughness, 0.001);
    float a2 = alpha * alpha;
    float dbase = nh * nh * (a2 - 1.0) + 1.0;
    float distribution = a2 / (3.14159265 * dbase * dbase);
    float gv = nl * sqrt(nv * nv * (1.0 - a2) + a2);
    float gl = nv * sqrt(nl * nl * (1.0 - a2) + a2);
    float visibility = 0.5 / max(gv + gl, 1e-5);
    vec3 diffuse = (1.0 - fresnel) * (1.0 - metallic) * color / 3.14159265;
    return (diffuse + fresnel * distribution * visibility) * energy * nl;
}

vec3 localResponse(uint count, vec3 position, vec3 color, float metallic, float roughness, vec3 n, vec3 v) {
    vec3 result = vec3(0);
    for (uint i = 0u; i < count; ++i) {
        LocalLight light = light_buffer.lights[i];
        vec3 delta = light.position_range.xyz - position;
        float distance2 = dot(delta, delta);
        vec3 l = delta * inversesqrt(max(distance2, 1e-12));
        float attenuation = 1.0;
        if (light.parameters.z < 0.5) {
            l = -light.direction_outer.xyz;
        } else {
            float range = light.position_range.w;
            if (range > 0.0) {
                float ratio2 = distance2 / (range * range);
                if (ratio2 >= 1.0) continue;
                float fade = max(1.0 - ratio2 * ratio2, 0.0);
                attenuation *= fade * fade;
            }
            attenuation /= max(distance2, light.parameters.y);
            if (light.parameters.z > 1.5) attenuation *= smoothstep(light.direction_outer.w, light.parameters.x, dot(-l, light.direction_outer.xyz));
        }
        result += directResponse(color, metallic, roughness, n, v, l, light.color_intensity.rgb * light.color_intensity.a * attenuation * shadowVisibility(light, position));
    }
    return result;
}
