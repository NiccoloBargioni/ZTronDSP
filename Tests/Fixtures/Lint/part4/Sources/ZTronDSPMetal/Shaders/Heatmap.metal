#include <metal_stdlib>
using namespace metal;

struct VertexOut { float4 position [[position]]; float2 uv; };

static float warp(float y) { return y * y; }                          // !! COV-4

vertex VertexOut heatmap_vertex(uint vertexID [[vertex_id]]) {         // !! COV-4
    VertexOut out;
    return out;
}

fragment float4 heatmap_fragment(VertexOut in [[stage_in]],            // !! COV-4
                                 texture2d<float> data [[texture(0)]]) {
    if (in.uv.x > 1.0) { return float4(0); }
    return float4(warp(in.uv.y));
}
