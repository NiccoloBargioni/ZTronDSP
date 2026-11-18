// Common.metal — what every render pass of the package shares.
//
// The sources in this folder are concatenated in the order of their names and compiled as one
// library when a MetalContext is created (change request CR-011), so this file comes first and
// the others use what it declares.

#include <metal_stdlib>
using namespace metal;

// One corner of the triangle that covers the whole target.
struct ZTDScreenVertex {
    float4 position [[position]];
    // Where the fragment is in the target: x from 0 at the left edge to 1 at the right edge,
    // y from 0 at the BOTTOM edge to 1 at the top edge. Rendering depends on these alone, never
    // on the target's size in pixels (SZ-1).
    float2 unit;
};

// A triangle that covers the target, from the vertex number alone: one draw call, no vertex
// buffer (§8.2).
vertex ZTDScreenVertex ztd_screen_vertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    ZTDScreenVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.unit = corner;
    return out;
}
