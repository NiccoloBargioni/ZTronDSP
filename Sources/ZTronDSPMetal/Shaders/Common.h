// Common.h — what more than one shader file of the package uses.
//
// The build compiles every .metal file of this folder on its own and links them into
// default.metallib in the module bundle, which a MetalContext loads (DEP-4). A type that two files
// use is therefore declared once, here, and each of those files includes this header.

#ifndef ZTD_SHADERS_COMMON_H
#define ZTD_SHADERS_COMMON_H

#include <metal_stdlib>

// One corner of the triangle that covers the whole target: what `ztd_screen_vertex`
// (Common.metal) hands every fragment function of a render pass.
struct ZTDScreenVertex {
    float4 position [[position]];
    // Where the fragment is in the target: x from 0 at the left edge to 1 at the right edge,
    // y from 0 at the BOTTOM edge to 1 at the top edge. Rendering depends on these alone, never
    // on the target's size in pixels (SZ-1).
    float2 unit;
};

#endif
