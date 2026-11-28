// Waveform.metal — the envelope fragment shader (WP-608, §8.2).
//
// The envelope texture holds (minimum, maximum) pairs as a linear array folded into rows of
// `rowWidth` texels: entry i is the texel (i % rowWidth, i / rowWidth). The first `capacity`
// entries are the slots of a ring, one pair per reduction bucket. They are followed by the
// reduced levels: an entry of level k + 1 holds the smaller minimum and the larger maximum of
// two entries of level k (an entry without a partner is carried up alone). A slot that holds
// no pair yet holds (+largest, -largest), which no reduction ever selects.
//
// What a fragment shows:
//   1. Time. The newest pair sits at the right edge; `visiblePairs` pairs span the width. The
//      fragment covers the pairs its width overlaps and takes the smallest minimum and the
//      largest maximum among them, exactly, by a walk up the levels: no peak is missed however
//      many pairs fall on one fragment.
//   2. Amplitude. The band between that minimum and that maximum, never thinner than one
//      fragment, is filled. The fragment's alpha is the share of its height the band covers:
//      analytic anti-aliasing.
//   3. Colour. Fill over background, premultiplied by alpha.

#include <metal_stdlib>
#include "Common.h"
using namespace metal;

struct ZTDWaveformUniforms {
    float4 fill;           // red, green, blue as display values, and opacity
    float4 background;     // the same for what lies behind the envelope
    float amplitudeLow;    // the amplitude at the bottom edge
    float amplitudeScale;  // 1 / (the amplitude at the top edge - amplitudeLow)
    float visiblePairs;    // pairs across the width
    uint head;             // the slot the next pair will be written to
    uint capacity;         // slots in the ring
    uint available;        // pairs the ring holds
    uint rowWidth;         // texels per row of the texture
    uint reserved;
};

// (smallest minimum, largest maximum) of the slots first ... last, both included and
// first <= last: the bottom-up walk of a segment tree whose levels are the reduced levels.
static float2 ztd_waveform_range(texture2d<float> data, uint first, uint last, uint capacity, uint rowWidth) {
    float2 result = float2(FLT_MAX, -FLT_MAX);
    uint offset = 0;
    uint count = capacity;
    while (first <= last) {
        if ((first & 1u) == 1u) {
            uint index = offset + first;
            float2 pair = data.read(uint2(index % rowWidth, index / rowWidth)).rg;
            result = float2(min(result.x, pair.x), max(result.y, pair.y));
            first += 1u;
        }
        if ((last & 1u) == 0u) {
            uint index = offset + last;
            float2 pair = data.read(uint2(index % rowWidth, index / rowWidth)).rg;
            result = float2(min(result.x, pair.x), max(result.y, pair.y));
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

fragment float4 ztd_waveform_fragment(ZTDScreenVertex in [[stage_in]],
                                      constant ZTDWaveformUniforms &uniforms [[buffer(0)]],
                                      texture2d<float> data [[texture(0)]]) {
    float pairsPerFragment = abs(dfdx(in.unit.x)) * uniforms.visiblePairs;
    float height = abs(dfdy(in.unit.y));

    // The ages this fragment covers, 0 being the newest pair. The stretch gives up a sliver at
    // each end (a 32nd of itself, at most a 64th of a pair), so that a pair whose boundary
    // coincides with the fragment's edge belongs to one fragment only.
    float centre = (1.0 - in.unit.x) * uniforms.visiblePairs;
    float sliver = min(pairsPerFragment / 32.0, 1.0 / 64.0);
    float youngest = max(centre - 0.5 * pairsPerFragment + sliver, 0.0);
    float oldest = max(centre + 0.5 * pairsPerFragment - sliver, youngest);

    float2 extent = float2(FLT_MAX, -FLT_MAX);
    uint firstAge = uint(youngest);
    if (firstAge < uniforms.available) {
        uint lastAge = min(uint(oldest), uniforms.available - 1u);
        // Ages run against the slots: the newest pair is in the slot before the head.
        uint newest = (uniforms.head + uniforms.capacity - 1u - firstAge) % uniforms.capacity;
        uint span = lastAge - firstAge;
        if (span <= newest) {
            extent = ztd_waveform_range(data, newest - span, newest, uniforms.capacity, uniforms.rowWidth);
        } else {
            // The run wraps round the end of the ring.
            float2 lower = ztd_waveform_range(data, 0u, newest, uniforms.capacity, uniforms.rowWidth);
            float2 upper = ztd_waveform_range(data, uniforms.capacity - (span - newest), uniforms.capacity - 1u,
                                              uniforms.capacity, uniforms.rowWidth);
            extent = float2(min(lower.x, upper.x), max(lower.y, upper.y));
        }
    }

    float coverage = 0.0;
    if (extent.x <= extent.y) {
        float bottom = (extent.x - uniforms.amplitudeLow) * uniforms.amplitudeScale;
        float top = (extent.y - uniforms.amplitudeLow) * uniforms.amplitudeScale;
        float middle = 0.5 * (bottom + top);
        float halfBand = max(0.5 * (top - bottom), 0.5 * height);
        float covered = min(middle + halfBand, in.unit.y + 0.5 * height) - max(middle - halfBand, in.unit.y - 0.5 * height);
        coverage = clamp(covered / height, 0.0, 1.0);
    }

    float fillAlpha = uniforms.fill.a * coverage;
    float backgroundAlpha = uniforms.background.a * (1.0 - fillAlpha);
    return float4(uniforms.fill.rgb * fillAlpha + uniforms.background.rgb * backgroundAlpha, fillAlpha + backgroundAlpha);
}
