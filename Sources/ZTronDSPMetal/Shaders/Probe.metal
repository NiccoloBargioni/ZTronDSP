// Probe.metal — the measurement behind a capability flag (WP-601, WP-604).
//
// Draws a half-float texture through a linear sampler. A MetalContext draws a texture of two
// texels, 0 and 1: where the device filters half-float textures the fragments between the two
// texel centres come out in between.

#include <metal_stdlib>
using namespace metal;

constexpr sampler ztd_probe_sampler(filter::linear, address::clamp_to_edge);

fragment float4 ztd_probe_fragment(ZTDScreenVertex in [[stage_in]], texture2d<float> data [[texture(0)]]) {
    float value = data.sample(ztd_probe_sampler, float2(in.unit.x, 0.5)).r;
    return float4(value, value, value, 1.0);
}
