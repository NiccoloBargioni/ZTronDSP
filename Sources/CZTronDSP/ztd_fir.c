#include <math.h>

#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* A product and a sum are rounded one after the other, never fused: a blend of two sets of taps
   is the same floats on every architecture. */
#pragma STDC FP_CONTRACT OFF

/* The direct FIR kernel (WP-212): y[n] = sum of taps[k] * x[n - k], on an input history and
   vDSP_conv.

   vDSP_conv computes C[n] = sum of A[n + p] * F[p], a correlation. The taps are therefore kept
   reversed, and A starts count - 1 frames before the frame whose output is wanted.

   The kernel works in cells of ZTD_FIR_CELL frames and makes one shape of call only, which is
   what makes it block-size invariant bit for bit (see ztd_internal.h). */

typedef struct ztd_fir {
    ztd_history_t history;
    uint32_t count;       /* taps */
    uint32_t fade_frames; /* frames a change of taps takes */
    ztd_crossfade_t fade; /* done while no change is in flight */
    float *taps;          /* reversed: the filter in force */
    float *next;          /* reversed: the filter being faded in */
    float *from, *to;     /* one cell of output each */
} ztd_fir_t;

static uint32_t ztd_fir_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                uint32_t frames) ZTD_NONBLOCKING {
    ztd_fir_t *fir = (ztd_fir_t *)state;
    const uint32_t count = ztd_min_u32(channels, fir->history.channels);
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t fill = fir->history.fill;
        const uint32_t chunk = ztd_min_u32(frames - done, ZTD_FIR_CELL - fill);
        const bool fading = !ztd_crossfade_is_done(&fir->fade);
        /* Frames of this chunk that still belong to the fade; the rest are the new filter's. */
        const uint32_t mixed = fading ? ztd_min_u32(chunk, fir->fade.total - fir->fade.position) : 0;
        ztd_crossfade_t fade = fir->fade;
        for (uint32_t channel = 0; channel < count; channel++) {
            const float *window = ztd_history_accept(&fir->history, channel, in[channel] + done, chunk);
            float *destination = out[channel] + done;
            /* Always a whole cell, always into the kernel's own aligned storage: every call has
               the same shape and the same alignment, whatever the block and wherever the caller
               keeps its buffer. The frames this block is owed are copied out. */
            if (!fading) {
                vDSP_conv(window, 1, fir->taps, 1, fir->to, 1, ZTD_FIR_CELL, fir->count);
                memcpy(destination, fir->to + fill, (size_t)chunk * sizeof(float));
            } else {
                vDSP_conv(window, 1, fir->taps, 1, fir->from, 1, ZTD_FIR_CELL, fir->count);
                vDSP_conv(window, 1, fir->next, 1, fir->to, 1, ZTD_FIR_CELL, fir->count);
                fade = fir->fade; /* every channel fades from the same place */
                ztd_crossfade_mix(&fade, fir->from + fill, fir->to + fill, destination, mixed);
                memcpy(destination + mixed, fir->to + fill + mixed, (size_t)(chunk - mixed) * sizeof(float));
            }
        }
        if (fading) {
            fir->fade = fade;
            if (ztd_crossfade_is_done(&fir->fade)) {
                float *finished = fir->taps;
                fir->taps = fir->next;
                fir->next = finished;
            }
        }
        ztd_history_advance(&fir->history, chunk);
        done += chunk;
    }
    return frames;
}

/* New taps of the same length, faded in over `fade_frames` frames (§5.5.4). */
static void ztd_fir_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_fir_t *fir = (ztd_fir_t *)state;
    if (!ztd_command_sets(command, fir->count)) return;
    const float *values = (const float *)command->values;
    if (!ztd_crossfade_is_done(&fir->fade)) {
        /* A change is already in flight. What sounds now is a blend of two filters, and a blend
           of two FIRs is one FIR: it becomes the filter to fade from, so the output does not
           jump. */
        const float gain = (float)fir->fade.position / (float)fir->fade.total;
        for (uint32_t tap = 0; tap < fir->count; tap++) {
            fir->taps[tap] = fir->taps[tap] + (fir->next[tap] - fir->taps[tap]) * gain;
        }
    }
    for (uint32_t tap = 0; tap < fir->count; tap++) fir->next[fir->count - 1 - tap] = values[tap];
    ztd_crossfade_begin(&fir->fade, fir->fade_frames);
}

/* A cold start keeps the taps last asked for and forgets the history and the fade. */
static void ztd_fir_reset(void *state) ZTD_NONBLOCKING {
    ztd_fir_t *fir = (ztd_fir_t *)state;
    ztd_history_reset(&fir->history);
    if (!ztd_crossfade_is_done(&fir->fade)) {
        float *finished = fir->taps;
        fir->taps = fir->next;
        fir->next = finished;
        fir->fade.position = fir->fade.total;
    }
}

static void ztd_fir_destroy(void *state) {
    ztd_fir_t *fir = (ztd_fir_t *)state;
    if (!fir) return;
    ztd_history_destroy(&fir->history);
    free(fir->taps);
    free(fir->next);
    free(fir->from);
    free(fir->to);
    free(fir);
}

bool ztd_taps_are_valid(const float *taps, uint32_t count) {
    if (!taps || count == 0 || count > ZTD_LIMIT) return false;
    for (uint32_t tap = 0; tap < count; tap++) {
        if (!isfinite(taps[tap])) return false;
    }
    return true;
}

ztd_kernel_t ztd_fir_create(uint32_t channels, const float *taps, uint32_t count, uint32_t latency_frames,
                            uint32_t fade_frames) {
    if (channels == 0 || channels > ZTD_LIMIT || !ztd_taps_are_valid(taps, count)) return ztd_kernel_null();
    ztd_fir_t *fir = (ztd_fir_t *)ztd_allocate(1, sizeof(ztd_fir_t));
    if (!fir) return ztd_kernel_null();
    fir->count = count;
    fir->fade_frames = fade_frames;
    fir->fade.total = 1; /* no change in flight */
    fir->fade.position = 1;
    fir->taps = (float *)ztd_allocate(count, sizeof(float));
    fir->next = (float *)ztd_allocate(count, sizeof(float));
    fir->from = (float *)ztd_allocate(ZTD_FIR_CELL, sizeof(float));
    fir->to = (float *)ztd_allocate(ZTD_FIR_CELL, sizeof(float));
    const bool ready = ztd_history_create(&fir->history, channels, count - 1, ZTD_FIR_CELL) && fir->taps &&
                       fir->next && fir->from && fir->to;
    if (!ready) {
        ztd_fir_destroy(fir);
        return ztd_kernel_null();
    }
    for (uint32_t tap = 0; tap < count; tap++) fir->taps[count - 1 - tap] = taps[tap];
    ztd_kernel_t kernel = {
        .process = ztd_fir_process,
        .command = ztd_fir_command,
        .reset = ztd_fir_reset,
        .destroy = ztd_fir_destroy,
        .state = fir,
        .latency_frames = latency_frames,
        .settling_frames = count - 1,
    };
    return kernel;
}
