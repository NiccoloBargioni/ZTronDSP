// Median.metal — the median of a whole spectrogram (WP-610, §6.10).
//
// The spectrogram is a buffer of `rowCount` values per column, column after column. For every
// element the kernel gathers the `laneCount` values around it along one axis, time (the same row
// of the neighbouring columns) or frequency (the neighbouring rows of the same column), and
// runs the selection network of WP-528 on them: a fixed list of compare-exchanges, each one a
// minimum and a maximum, after which one known lane holds the median. Edges are reflected with
// the edge value repeated: x[-k] = x[k - 1] (§6.1).
//
// There is no arithmetic here, only comparisons, and the comparisons are made on integers: a
// GPU is free to treat subnormal floats as zero, and then cannot tell 1e-40 from 0. Each value
// is therefore read as its 32 bits and turned into a key, an unsigned integer that orders as
// the float does (negative values reversed below the positive ones, -0 below +0, which is the
// order of the minimum and maximum of IEEE 754-2019 that the CPU lanes use). The network runs
// on the keys, and the median's key is turned back into the bits it came from. The result is
// one of the input values, bit for bit.

#include <metal_stdlib>
using namespace metal;

struct ZTDMedianUniforms {
    uint rowCount;       // values per column
    uint columnCount;    // columns in the buffer
    uint laneCount;      // values the median is taken over: an odd number, at most 255
    uint exchangeCount;  // compare-exchanges of the network
    uint medianLane;     // the lane that holds the median afterwards
    uint alongTime;      // 1: across columns; 0: across rows
    uint firstColumn;    // the column this dispatch starts at
    uint columnsHere;    // columns this dispatch computes
};

kernel void ztd_median_kernel(uint2 position [[thread_position_in_grid]],
                              constant ZTDMedianUniforms &uniforms [[buffer(0)]],
                              const device uint *input [[buffer(1)]],
                              device uint *output [[buffer(2)]],
                              const device ushort *exchanges [[buffer(3)]]) {
    if (position.x >= uniforms.columnsHere || position.y >= uniforms.rowCount) { return; }
    uint column = uniforms.firstColumn + position.x;
    uint row = position.y;

    uint lanes[255];
    int extent = int(uniforms.alongTime != 0u ? uniforms.columnCount : uniforms.rowCount);
    int centre = int(uniforms.alongTime != 0u ? column : row);
    int reach = int(uniforms.laneCount / 2u);
    for (uint lane = 0u; lane < uniforms.laneCount; ++lane) {
        // Reflection with the edge value repeated has the period 2 * extent.
        int index = centre + int(lane) - reach;
        int period = 2 * extent;
        index = ((index % period) + period) % period;
        if (index >= extent) { index = period - 1 - index; }
        uint source = uniforms.alongTime != 0u ? uint(index) * uniforms.rowCount + row
                                               : column * uniforms.rowCount + uint(index);
        uint bits = input[source];
        lanes[lane] = (bits & 0x80000000u) != 0u ? ~bits : (bits | 0x80000000u);
    }
    for (uint step = 0u; step < uniforms.exchangeCount; ++step) {
        uint low = uint(exchanges[2u * step]);
        uint high = uint(exchanges[2u * step + 1u]);
        uint a = lanes[low];
        uint b = lanes[high];
        lanes[low] = min(a, b);
        lanes[high] = max(a, b);
    }
    uint key = lanes[uniforms.medianLane];
    output[column * uniforms.rowCount + row] = (key & 0x80000000u) != 0u ? (key & 0x7FFFFFFFu) : ~key;
}
