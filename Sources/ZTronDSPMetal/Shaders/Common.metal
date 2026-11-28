// Common.metal — what every render pass of the package shares.
//
// The build compiles each file of this folder on its own and links them into default.metallib in
// the module bundle (DEP-4). The vertex type that the fragment functions of the other files take
// is declared in Common.h, which they include.

#include <metal_stdlib>
#include "Common.h"
using namespace metal;

// A triangle that covers the target, from the vertex number alone: one draw call, no vertex
// buffer (§8.2).
vertex ZTDScreenVertex ztd_screen_vertex(uint vertexID [[vertex_id]]) {
    float2 corner = float2(float((vertexID << 1) & 2), float(vertexID & 2));
    ZTDScreenVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.unit = corner;
    return out;
}
