// Heatmap.metal — the heat-map fragment shader (WP-605, §8.2).
//
// The data texture is a ring of columns. One column is one ROW of texels: its bins, followed
// by its max-reduced levels (level k + 1 holds, for every pair of entries of level k, the
// larger; an entry without a partner is carried up alone). The texture's y coordinate is the
// slot in the ring.
//
// What a fragment shows:
//   1. Time. The newest column sits at the right edge; `visibleColumns` columns span the
//      width. The fragment shows the column its centre falls in. Columns the ring does not
//      hold yet show the lowest value.
//   2. Frequency. The warp table turns a position on the display axis into a row coordinate
//      (row k is the integer k). The fragment covers the rows between the coordinates of its
//      lower and its upper edge, and shows the MAXIMUM, over that stretch, of the values
//      between the rows: linear interpolation between neighbouring rows, or the nearest row.
//      A fragment narrower than a row therefore shows the interpolated value; a fragment that
//      covers several rows shows the largest of them, so a one-bin peak is visible at every
//      scale (V-8). The rows inside the stretch are reduced exactly, by a walk up the levels.
//   3. Colour. The value is normalised against the value range, clamped, and looked up in the
//      256-entry colour table, linearly between neighbouring entries.

#include <metal_stdlib>
#include "Common.h"
using namespace metal;

struct ZTDHeatmapUniforms {
    float valueLow;        // the value shown as the first colour
    float valueScale;      // 1 / (the value shown as the last colour - valueLow)
    float positionLow;     // the bottom edge of the target on the warp table's axis, 0 ... 1
    float positionHigh;    // the top edge
    float visibleColumns;  // columns across the width
    uint head;             // the slot the next column will be written to
    uint history;          // slots in the ring
    uint available;        // columns the ring holds
    uint binCount;         // rows per column
    uint warpSize;         // entries in the warp table
    uint nearest;          // 1: the nearest row; 0: linear between rows
    uint reserved;
};

// The largest value of rows first ... last (both included, first <= last) of the column in
// `slot`: the bottom-up walk of a segment tree whose levels are the reduced levels.
static float ztd_heatmap_range_max(texture2d<float> data, uint slot, uint first, uint last, uint binCount) {
    float result = -FLT_MAX;
    uint offset = 0;
    uint count = binCount;
    while (first <= last) {
        if ((first & 1u) == 1u) {
            result = max(result, data.read(uint2(offset + first, slot)).r);
            first += 1u;
        }
        if ((last & 1u) == 0u) {
            result = max(result, data.read(uint2(offset + last, slot)).r);
            if (last == 0u) { break; }
            last -= 1u;
        }
        if (first > last) { break; }
        first >>= 1u;
        last >>= 1u;
        offset += count;
        count = (count + 1u) >> 1u;
    }
    return result;
}

// The row coordinate at `unitY` of the target: the warp table, linear between its entries.
static float ztd_heatmap_row(texture2d<float> warp, float unitY, float positionLow, float positionHigh, uint warpSize) {
    float position = clamp(positionLow + unitY * (positionHigh - positionLow), 0.0, 1.0);
    float scaled = position * float(warpSize - 1u);
    uint index = min(uint(scaled), warpSize - 2u);
    float lower = warp.read(uint2(index, 0u)).r;
    float upper = warp.read(uint2(index + 1u, 0u)).r;
    return mix(lower, upper, scaled - float(index));
}

// The value between the rows at the coordinate `row` (0 ... binCount - 1): linear.
static float ztd_heatmap_between(texture2d<float> data, uint slot, float row, uint binCount) {
    uint below = min(uint(row), binCount - 1u);
    uint above = min(below + 1u, binCount - 1u);
    float lower = data.read(uint2(below, slot)).r;
    float upper = data.read(uint2(above, slot)).r;
    return mix(lower, upper, row - float(below));
}

fragment float4 ztd_heatmap_fragment(ZTDScreenVertex in [[stage_in]],
                                     constant ZTDHeatmapUniforms &uniforms [[buffer(0)]],
                                     texture2d<float> data [[texture(0)]],
                                     texture2d<float> warp [[texture(1)]],
                                     texture2d<float> colors [[texture(2)]]) {
    // Half the height of this fragment, in units of the target's height.
    float halfHeight = 0.5 * abs(dfdy(in.unit.y));

    float age = max((1.0 - in.unit.x) * uniforms.visibleColumns, 0.0);
    uint column = uint(age);
    float value = uniforms.valueLow;

    if (column < uniforms.available) {
        uint slot = (uniforms.head + uniforms.history - 1u - column) % uniforms.history;
        float top = float(uniforms.binCount - 1u);
        float edgeA = ztd_heatmap_row(warp, in.unit.y - halfHeight, uniforms.positionLow, uniforms.positionHigh, uniforms.warpSize);
        float edgeB = ztd_heatmap_row(warp, in.unit.y + halfHeight, uniforms.positionLow, uniforms.positionHigh, uniforms.warpSize);
        float low = clamp(min(edgeA, edgeB), 0.0, top);
        float high = clamp(max(edgeA, edgeB), 0.0, top);

        if (uniforms.nearest != 0u) {
            // Each row is a cell of height one around its coordinate. The stretch gives up a
            // sliver at each end (a 32nd of itself, at most a 64th of a row), so that a cell
            // boundary that coincides with a fragment's edge belongs to one fragment only.
            float sliver = min((high - low) / 32.0, 1.0 / 64.0);
            uint first = min(uint(low + sliver + 0.5), uniforms.binCount - 1u);
            uint last = min(uint(max(high - sliver, low) + 0.5), uniforms.binCount - 1u);
            value = ztd_heatmap_range_max(data, slot, first, max(first, last), uniforms.binCount);
        } else {
            // The interpolant is piecewise linear, so its maximum over the stretch is reached
            // at one of its ends or at a row inside it.
            value = max(ztd_heatmap_between(data, slot, low, uniforms.binCount),
                        ztd_heatmap_between(data, slot, high, uniforms.binCount));
            uint first = uint(ceil(low));
            uint last = uint(floor(high));
            if (first <= last) {
                value = max(value, ztd_heatmap_range_max(data, slot, first, last, uniforms.binCount));
            }
        }
    }

    float normalised = clamp((value - uniforms.valueLow) * uniforms.valueScale, 0.0, 1.0);
    float scaled = normalised * 255.0;
    uint entry = min(uint(scaled), 254u);
    float4 lower = colors.read(uint2(entry, 0u));
    float4 upper = colors.read(uint2(entry + 1u, 0u));
    return float4(mix(lower.rgb, upper.rgb, scaled - float(entry)), 1.0);
}
