#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* The rate changers: the decimator (WP-213), the interpolator (WP-223), and the two hooks
   without a filter, subsample and zero-stuff (WP-227). Each carries its phase across blocks, so
   any sequence of block sizes gives the same output stream. */

/* --- Decimator: low-pass, then keep every `factor`-th frame ------------------------------------

   Output m is y[m * factor], with y the full-rate filter output, so the first input frame is
   kept. vDSP_desamp computes C[n] = sum of A[n * factor + p] * F[p]: the taps are kept reversed
   and A starts count - 1 frames before the cell. A cell is ZTD_DECIMATOR_CELL outputs, which is
   that many times `factor` input frames; where the kernel stands in the cell is its phase. */

typedef struct ztd_decimator {
    ztd_history_t history; /* a cell is ZTD_DECIMATOR_CELL * factor input frames */
    uint32_t count;
    uint32_t factor;
    float *taps;    /* reversed */
    float *scratch; /* one cell of output */
} ztd_decimator_t;

static uint32_t ztd_decimator_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                      uint32_t frames) ZTD_NONBLOCKING {
    ztd_decimator_t *decimator = (ztd_decimator_t *)state;
    const uint32_t count = ztd_min_u32(channels, decimator->history.channels);
    const uint32_t factor = decimator->factor;
    const uint32_t span = decimator->history.cell;
    uint32_t done = 0, written = 0;
    while (done < frames) {
        const uint32_t fill = decimator->history.fill;
        const uint32_t chunk = ztd_min_u32(frames - done, span - fill);
        /* Output j of the cell is due as soon as input frame j * factor of the cell is in. */
        const uint32_t before = (fill + factor - 1) / factor;
        const uint32_t after = (fill + chunk + factor - 1) / factor;
        for (uint32_t channel = 0; channel < count; channel++) {
            const float *window = ztd_history_accept(&decimator->history, channel, in[channel] + done, chunk);
            if (after == before) continue;
            /* Always a whole cell, always into the kernel's own aligned storage: every call has
               the same shape and the same alignment, whatever the block and wherever the caller
               keeps its buffer. The outputs that became due are copied out. */
            vDSP_desamp(window, (vDSP_Stride)factor, decimator->taps, decimator->scratch, ZTD_DECIMATOR_CELL,
                        decimator->count);
            memcpy(out[channel] + written, decimator->scratch + before, (size_t)(after - before) * sizeof(float));
        }
        written += after - before;
        ztd_history_advance(&decimator->history, chunk);
        done += chunk;
    }
    return written;
}

static void ztd_decimator_reset(void *state) ZTD_NONBLOCKING {
    ztd_decimator_t *decimator = (ztd_decimator_t *)state;
    ztd_history_reset(&decimator->history);
}

static void ztd_decimator_destroy(void *state) {
    ztd_decimator_t *decimator = (ztd_decimator_t *)state;
    if (!decimator) return;
    ztd_history_destroy(&decimator->history);
    free(decimator->taps);
    free(decimator->scratch);
    free(decimator);
}

ztd_kernel_t ztd_decimator_create(uint32_t channels, uint32_t factor, const float *taps, uint32_t count,
                                  uint32_t latency_frames) {
    if (channels == 0 || channels > ZTD_LIMIT || factor == 0 || factor > ZTD_RATE_FACTOR_LIMIT ||
        !ztd_taps_are_valid(taps, count)) {
        return ztd_kernel_null();
    }
    ztd_decimator_t *decimator = (ztd_decimator_t *)ztd_allocate(1, sizeof(ztd_decimator_t));
    if (!decimator) return ztd_kernel_null();
    decimator->count = count;
    decimator->factor = factor;
    decimator->taps = (float *)ztd_allocate(count, sizeof(float));
    decimator->scratch = (float *)ztd_allocate(ZTD_DECIMATOR_CELL, sizeof(float));
    const bool ready = ztd_history_create(&decimator->history, channels, count - 1, ZTD_DECIMATOR_CELL * factor) &&
                       decimator->taps && decimator->scratch;
    if (!ready) {
        ztd_decimator_destroy(decimator);
        return ztd_kernel_null();
    }
    for (uint32_t tap = 0; tap < count; tap++) decimator->taps[count - 1 - tap] = taps[tap];
    ztd_kernel_t kernel = {
        .process = ztd_decimator_process,
        .command = NULL,
        .reset = ztd_decimator_reset,
        .destroy = ztd_decimator_destroy,
        .state = decimator,
        .latency_frames = latency_frames,
        .settling_frames = count - 1,
    };
    return kernel;
}

/* --- Interpolator: zero-stuff, then low-pass with gain `factor`, as a polyphase filter ---------

   With u the zero-stuffed input, y[m] = factor * sum of taps[k] * u[m - k]. Only every
   `factor`-th u is not zero, so output n * factor + p is

       factor * sum over j of taps[j * factor + p] * x[n - j]

   which is `factor` short filters, one per output phase p, and no multiplication is spent on an
   inserted zero. Phase p is one vDSP_conv over the input with an output stride of `factor`. The
   gain is folded into the phase taps when the kernel is created. */

typedef struct ztd_interpolator {
    ztd_history_t history; /* a cell is ZTD_INTERPOLATOR_CELL input frames */
    uint32_t factor;
    uint32_t phase_taps; /* taps per phase: ceil(count / factor) */
    float *phases;       /* factor filters of phase_taps taps, each reversed */
    float *scratch;      /* one cell of output: ZTD_INTERPOLATOR_CELL * factor frames */
} ztd_interpolator_t;

static uint32_t ztd_interpolator_process(void *state, const float *const *in, float *const *out,
                                         uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_interpolator_t *interpolator = (ztd_interpolator_t *)state;
    const uint32_t count = ztd_min_u32(channels, interpolator->history.channels);
    const uint32_t factor = interpolator->factor;
    const uint32_t phase_taps = interpolator->phase_taps;
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t fill = interpolator->history.fill;
        const uint32_t chunk = ztd_min_u32(frames - done, ZTD_INTERPOLATOR_CELL - fill);
        for (uint32_t channel = 0; channel < count; channel++) {
            const float *window = ztd_history_accept(&interpolator->history, channel, in[channel] + done, chunk);
            /* Always a whole cell, always into the kernel's own aligned storage: every call has
               the same shape and the same alignment. The frames this block is owed are copied out. */
            for (uint32_t phase = 0; phase < factor; phase++) {
                vDSP_conv(window, 1, interpolator->phases + (size_t)phase * phase_taps, 1, interpolator->scratch + phase,
                          (vDSP_Stride)factor, ZTD_INTERPOLATOR_CELL, phase_taps);
            }
            memcpy(out[channel] + (size_t)done * factor, interpolator->scratch + (size_t)fill * factor,
                   (size_t)chunk * factor * sizeof(float));
        }
        ztd_history_advance(&interpolator->history, chunk);
        done += chunk;
    }
    return frames * factor;
}

static void ztd_interpolator_reset(void *state) ZTD_NONBLOCKING {
    ztd_interpolator_t *interpolator = (ztd_interpolator_t *)state;
    ztd_history_reset(&interpolator->history);
}

static void ztd_interpolator_destroy(void *state) {
    ztd_interpolator_t *interpolator = (ztd_interpolator_t *)state;
    if (!interpolator) return;
    ztd_history_destroy(&interpolator->history);
    free(interpolator->phases);
    free(interpolator->scratch);
    free(interpolator);
}

ztd_kernel_t ztd_interpolator_create(uint32_t channels, uint32_t factor, const float *taps, uint32_t count,
                                     uint32_t latency_frames) {
    if (channels == 0 || channels > ZTD_LIMIT || factor == 0 || factor > ZTD_RATE_FACTOR_LIMIT ||
        !ztd_taps_are_valid(taps, count)) {
        return ztd_kernel_null();
    }
    ztd_interpolator_t *interpolator = (ztd_interpolator_t *)ztd_allocate(1, sizeof(ztd_interpolator_t));
    if (!interpolator) return ztd_kernel_null();
    const uint32_t phase_taps = (count + factor - 1) / factor;
    interpolator->factor = factor;
    interpolator->phase_taps = phase_taps;
    interpolator->phases = (float *)ztd_allocate((size_t)factor * phase_taps, sizeof(float));
    interpolator->scratch = (float *)ztd_allocate((size_t)ZTD_INTERPOLATOR_CELL * factor, sizeof(float));
    const bool ready = ztd_history_create(&interpolator->history, channels, phase_taps - 1, ZTD_INTERPOLATOR_CELL) &&
                       interpolator->phases && interpolator->scratch;
    if (!ready) {
        ztd_interpolator_destroy(interpolator);
        return ztd_kernel_null();
    }
    for (uint32_t phase = 0; phase < factor; phase++) {
        float *filter = interpolator->phases + (size_t)phase * phase_taps;
        for (uint32_t index = 0; index < phase_taps; index++) {
            /* Tap j of this phase is taps[j * factor + phase]; a phase shorter than the others
               ends in zeros. Reversed for vDSP_conv, with the gain folded in. */
            const uint64_t tap = (uint64_t)(phase_taps - 1 - index) * factor + phase;
            filter[index] = tap < count ? (float)factor * taps[tap] : 0.0f;
        }
    }
    ztd_kernel_t kernel = {
        .process = ztd_interpolator_process,
        .command = NULL,
        .reset = ztd_interpolator_reset,
        .destroy = ztd_interpolator_destroy,
        .state = interpolator,
        .latency_frames = latency_frames,
        .settling_frames = phase_taps - 1,
    };
    return kernel;
}

/* --- Subsample: keep every `factor`-th frame, no filter ----------------------------------------- */

typedef struct ztd_subsample {
    uint32_t channels;
    uint32_t factor;
    uint32_t phase; /* as created, already wrapped into 0 ..< factor */
    uint32_t skip;  /* frames to pass over before the next one that is kept */
} ztd_subsample_t;

static uint32_t ztd_subsample_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                      uint32_t frames) ZTD_NONBLOCKING {
    ztd_subsample_t *subsample = (ztd_subsample_t *)state;
    const uint32_t count = ztd_min_u32(channels, subsample->channels);
    const uint32_t factor = subsample->factor;
    const uint32_t first = subsample->skip;
    if (first >= frames) {
        subsample->skip = first - frames;
        return 0;
    }
    const uint32_t written = (frames - first - 1) / factor + 1;
    for (uint32_t channel = 0; channel < count; channel++) {
        const float *restrict source = in[channel] + first;
        float *restrict destination = out[channel];
        for (uint32_t index = 0; index < written; index++) destination[index] = source[(size_t)index * factor];
    }
    /* The frame kept next is first + written * factor of this block; the block ends at `frames`. */
    subsample->skip = (uint32_t)((uint64_t)first + (uint64_t)written * factor - frames);
    return written;
}

static void ztd_subsample_reset(void *state) ZTD_NONBLOCKING {
    ztd_subsample_t *subsample = (ztd_subsample_t *)state;
    subsample->skip = subsample->phase;
}

static void ztd_rate_free(void *state) {
    free(state);
}

ztd_kernel_t ztd_subsample_create(uint32_t channels, uint32_t factor, uint32_t phase) {
    if (channels == 0 || channels > ZTD_LIMIT || factor == 0 || factor > ZTD_RATE_FACTOR_LIMIT) return ztd_kernel_null();
    ztd_subsample_t *subsample = (ztd_subsample_t *)ztd_allocate(1, sizeof(ztd_subsample_t));
    if (!subsample) return ztd_kernel_null();
    subsample->channels = channels;
    subsample->factor = factor;
    subsample->phase = phase % factor;
    subsample->skip = subsample->phase;
    ztd_kernel_t kernel = {
        .process = ztd_subsample_process,
        .command = NULL,
        .reset = ztd_subsample_reset,
        .destroy = ztd_rate_free,
        .state = subsample,
        .latency_frames = 0,
        .settling_frames = 0,
    };
    return kernel;
}

/* --- Zero-stuff: `factor - 1` zeros after each frame, no filter ---------------------------------

   Every input frame gives exactly `factor` output frames, so there is no phase to carry: the
   kernel has no memory. */

typedef struct ztd_zero_stuff {
    uint32_t channels;
    uint32_t factor;
} ztd_zero_stuff_t;

static uint32_t ztd_zero_stuff_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                       uint32_t frames) ZTD_NONBLOCKING {
    const ztd_zero_stuff_t *stuff = (const ztd_zero_stuff_t *)state;
    const uint32_t count = ztd_min_u32(channels, stuff->channels);
    const uint32_t factor = stuff->factor;
    for (uint32_t channel = 0; channel < count; channel++) {
        const float *restrict source = in[channel];
        float *restrict destination = out[channel];
        memset(destination, 0, (size_t)frames * factor * sizeof(float));
        for (uint32_t frame = 0; frame < frames; frame++) destination[(size_t)frame * factor] = source[frame];
    }
    return frames * factor;
}

static void ztd_zero_stuff_reset(void *state) ZTD_NONBLOCKING {
    (void)state;
}

ztd_kernel_t ztd_zero_stuff_create(uint32_t channels, uint32_t factor) {
    if (channels == 0 || channels > ZTD_LIMIT || factor == 0 || factor > ZTD_RATE_FACTOR_LIMIT) return ztd_kernel_null();
    ztd_zero_stuff_t *stuff = (ztd_zero_stuff_t *)ztd_allocate(1, sizeof(ztd_zero_stuff_t));
    if (!stuff) return ztd_kernel_null();
    stuff->channels = channels;
    stuff->factor = factor;
    ztd_kernel_t kernel = {
        .process = ztd_zero_stuff_process,
        .command = NULL,
        .reset = ztd_zero_stuff_reset,
        .destroy = ztd_rate_free,
        .state = stuff,
        .latency_frames = 0,
        .settling_frames = 0,
    };
    return kernel;
}
