#include <metal_stdlib>
using namespace metal;

vertex float4 heatmap_vertex(uint vertexID [[vertex_id]]) {
    return float4(0);
}

fragment float4 heatmap_fragment(float4 position [[position]]) {
    return float4(0);
}
