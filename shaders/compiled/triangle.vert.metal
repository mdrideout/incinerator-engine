#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

struct main0_out
{
    float3 frag_color [[user(locn0)]];
    float4 gl_Position [[position]];
};

struct main0_in
{
    float3 in_position [[attribute(0)]];
    float3 in_color [[attribute(1)]];
};

vertex main0_out main0(main0_in in [[stage_in]])
{
    main0_out out = {};
    out.frag_color = in.in_color;
    out.gl_Position = float4(in.in_position, 1.0);
    return out;
}

