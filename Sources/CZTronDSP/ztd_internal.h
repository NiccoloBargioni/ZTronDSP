#ifndef ZTD_INTERNAL_H
#define ZTD_INTERNAL_H

/* Private helpers shared by the kernels of this target. Nothing here is part of the ABI. */

#include <stdlib.h>
#include <string.h>

#include "ztd_kernel.h"
#include "ztd_kernels.h"

/* The largest channel count, tap count, section count or kernel count a constructor accepts. It
   keeps every size computation far from overflow; nothing real comes near it. */
#define ZTD_LIMIT ((uint32_t)1 << 24)

/* The most samples (frames times channels) one buffer of a plan holds: a gigabyte of Float32,
   which is what a feed's history may come to as well. A plan that asks for more is one no
   machine is asked to hold: it is refused before the buffer is asked for, so nothing is
   allocated and zeroed for a plan that cannot be (§9.3). */
#define ZTD_PLAN_SAMPLE_LIMIT ((size_t)1 << 28)

/* --- A seam for the tests of failed creation ---------------------------------------------------
   Every constructor of this target (the kernels, the ring, the plan and its switches, the
   queues, the plan slot, the atomic cells, the parker) asks ztd_may_allocate() before it asks
   the system for memory, a mapping or a setup, and takes "no" as the system's refusal. The answer is always
   yes, unless a test has asked for the n-th request of its own thread to be refused
   (ztd_fail_allocation): that is the only way to reach what a constructor does when the system
   has nothing to give, which is to free what it has and return nothing. The count is per thread,
   so tests that run side by side do not disturb one another. Control context only: nothing on
   the hot path asks. Not in a public header: the tests reach the two functions by name. */
bool ztd_may_allocate(void);
/* Refuses request number `index` of the calling thread, counted from this call and from 0, once;
   a negative index refuses none. */
void ztd_fail_allocation(int32_t index);
/* True while a refusal asked for has not happened yet: the constructor made fewer requests. */
bool ztd_allocation_failure_is_pending(void);

/* Zero-filled storage for `count` elements of `size` bytes, aligned to a cache line (which is
   more than the 16 bytes vDSP asks for). NULL when the system has no memory to give. A count of
   zero still yields a valid pointer. Control context only: it allocates. */
static inline void *ztd_allocate(size_t count, size_t size) {
    if (!ztd_may_allocate()) return NULL;
    if (size != 0 && count > (SIZE_MAX / 2) / size) return NULL;
    size_t bytes = count * size;
    if (bytes < 64) bytes = 64;
    void *memory = NULL;
    if (posix_memalign(&memory, 64, bytes) != 0) return NULL;
    /* Writing the zeros also touches every page, so the hot path takes no first-touch fault. */
    memset(memory, 0, bytes);
    return memory;
}

/* The kernel a constructor returns when it cannot create one: `process` is NULL
   (ztd_kernel_is_null). */
static inline ztd_kernel_t ztd_kernel_null(void) {
    ztd_kernel_t kernel;
    memset(&kernel, 0, sizeof kernel);
    return kernel;
}

static inline uint32_t ztd_min_u32(uint32_t a, uint32_t b) {
    return a < b ? a : b;
}

/* Four Float32 lanes, loaded and stored without any requirement on alignment.

   The package manager compiles a C target for size in release builds (-Os), and at that
   setting the compiler does not turn a loop into vector code when the loop needs a scalar
   remainder, `restrict` or not (measured: 0.4 ns per frame for `out = in * gain`, against
   0.07 ns for vDSP_vsmul at 512 frames). Where a native loop is worth it, the kernels therefore
   spell the four lanes out. An operation on the lanes is the IEEE operation of the scalar loop,
   lane by lane: the floats are the same. */
typedef float ztd_float4 __attribute__((vector_size(16), aligned(4), may_alias));

static inline ztd_float4 ztd_load4(const float *source) {
    ztd_float4 lanes;
    memcpy(&lanes, source, sizeof lanes);
    return lanes;
}

static inline void ztd_store4(float *destination, ztd_float4 lanes) {
    memcpy(destination, &lanes, sizeof lanes);
}

/* True for a ZTD_COMMAND_SET_VALUES command that carries exactly `count` values. */
static inline bool ztd_command_sets(const ztd_command_t *command, uint32_t count) {
    return command && command->kind == ZTD_COMMAND_SET_VALUES && command->values && command->count == count;
}

/* The settling time a biquad cascade reports: the frames its slowest pole needs to decay by
   100 dB, from the pole radii of the sections (b0 b1 b2 a1 a2 each). 0 for a cascade without
   poles; ZTD_BIQUAD_SETTLING_CAP for one that does not decay. Control context. */
#define ZTD_BIQUAD_SETTLING_CAP ((uint32_t)1 << 24)
uint32_t ztd_biquad_settling(const double *coefficients, uint32_t sections);

/* What the three biquad constructors accept: at least one channel and one section, finite
   coefficients, and a state small enough to count in 32 bits. */
bool ztd_biquad_arguments_are_valid(uint32_t channels, uint32_t sections, const double *coefficients);

/* What the FIR-shaped constructors accept as taps: a pointer, 1 … ZTD_LIMIT of them, all finite. */
bool ztd_taps_are_valid(const float *taps, uint32_t count);

/* The largest factor a rate changer accepts. */
#define ZTD_RATE_FACTOR_LIMIT 4096u

/* --- Cells -------------------------------------------------------------------------------------
   vDSP_conv and vDSP_desamp do not round an output the same way in every call: the result
   depends on where the output sits in the call and on the call's length (measured on the host
   of §3: for 255 taps, four in ten outputs of one call of 6 000 differ in the last bits from
   the same outputs computed in shorter calls; with an output stride vDSP_conv rounds
   differently again). A kernel that handed them whatever block it was given would therefore
   not be block-size invariant.

   The history kernels (FIR, decimator, interpolator) instead cut the stream into cells of a
   fixed number of frames, counted from the kernel's first frame, and only ever make calls of
   one shape: a whole cell, read from the kernel's own aligned history and written to the
   kernel's own aligned scratch, so that nothing about the caller's buffers enters a call
   either. (vDSP_biquad is known to round differently into an output that is aligned
   differently. vDSP_conv and vDSP_desamp were measured not to on the toolchain of §3; the
   kernels do not rely on that.) Output n is always element n mod cell of such a call, whatever
   the blocks are and wherever the caller keeps its buffers, so the output stream is the same
   bit for bit for any sequence of block sizes.

   A block that ends inside a cell computes the cell on what has arrived (the rest reads as
   zero, and its outputs are not used) and the next block computes it again. Blocks that are
   whole cells compute each cell once; what they pay is one copy of the cell from the scratch
   to the output. */
#define ZTD_FIR_CELL 64u          /* frames per cell of the direct FIR */
#define ZTD_INTERPOLATOR_CELL 64u /* input frames per cell of the interpolator */
#define ZTD_DECIMATOR_CELL 16u    /* output frames per cell of the decimator */

/* The input history of such a kernel: per channel one contiguous buffer that holds, for the
   cell being filled, the `past` frames before it and the cell itself, so the window a
   convolution reads never wraps. The buffer holds several cells in a row; when the last one is
   full its tail is moved to the front (once per `cells` cells, so the cost is amortised away).

   Input is cleaned as it enters: a sample below ZTD_STATE_FLOOR in magnitude is stored as zero
   (RT-6). Because that happens per sample, on entry, it does not depend on the block sizes. */
typedef struct ztd_history {
    uint32_t channels;
    uint32_t past;   /* frames kept before a cell: the filter length minus one */
    uint32_t cell;   /* input frames per cell */
    uint32_t cells;  /* cells the buffer holds after its first `past` frames */
    uint32_t index;  /* the cell being filled */
    uint32_t fill;   /* input frames already in it: 0 ..< cell */
    float **buffer;  /* per channel: past + cells * cell frames */
} ztd_history_t;

/* Control context. On failure the caller still calls ztd_history_destroy. */
bool ztd_history_create(ztd_history_t *history, uint32_t channels, uint32_t past, uint32_t cell);
void ztd_history_destroy(ztd_history_t *history);
void ztd_history_reset(ztd_history_t *history) ZTD_NONBLOCKING;

/* Copies `frames` new frames of one channel into the cell being filled (frames <= cell - fill)
   and returns the cell's window: `past` frames of history followed by the cell. What has not
   arrived yet reads as zero. Call it for every channel, then ztd_history_advance once. */
const float *ztd_history_accept(ztd_history_t *history, uint32_t channel, const float *in,
                                uint32_t frames) ZTD_NONBLOCKING;
void ztd_history_advance(ztd_history_t *history, uint32_t frames) ZTD_NONBLOCKING;

#endif /* ZTD_INTERNAL_H */
