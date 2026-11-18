#include <math.h>

#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* The single-precision biquad cascades: the mono-setup kernel on vDSP_biquad or a C loop
   (WP-208), its live coefficient update (WP-209), and the multichannel kernel on vDSP_biquadm
   (WP-210). The double-precision kernel is in ztd_biquad_double.c. */

/* The C loop rounds every product and every sum on its own, in the order written, so a scalar
   reference in any language reproduces it bit for bit. */
#pragma STDC FP_CONTRACT OFF

/* --- Settling time ---------------------------------------------------------------------------- */

uint32_t ztd_biquad_settling(const double *coefficients, uint32_t sections) {
    double radius = 0.0;
    for (uint32_t section = 0; section < sections; section++) {
        const double a1 = coefficients[5 * section + 3], a2 = coefficients[5 * section + 4];
        const double discriminant = a1 * a1 - 4.0 * a2;
        double largest;
        if (discriminant < 0.0) {
            largest = sqrt(a2); /* a conjugate pair: |p|^2 = a2 */
        } else {
            const double root = sqrt(discriminant);
            largest = fmax(fabs(-a1 + root), fabs(-a1 - root)) / 2.0;
        }
        if (!(largest <= radius)) radius = largest; /* a NaN is kept, and caps the result below */
    }
    if (radius == 0.0) return 0;
    if (!(radius < 1.0)) return ZTD_BIQUAD_SETTLING_CAP;
    /* Frames for radius^n to fall by 100 dB. */
    const double frames = ceil(log(1e-5) / log(radius));
    return frames < (double)ZTD_BIQUAD_SETTLING_CAP ? (uint32_t)frames : ZTD_BIQUAD_SETTLING_CAP;
}

bool ztd_biquad_arguments_are_valid(uint32_t channels, uint32_t sections, const double *coefficients) {
    if (channels == 0 || channels > ZTD_LIMIT || sections == 0 || sections > ZTD_LIMIT || !coefficients) return false;
    if ((uint64_t)channels * (2 * (uint64_t)sections + 2) > ((uint64_t)1 << 28)) return false;
    for (uint32_t index = 0; index < 5 * sections; index++) {
        if (!isfinite(coefficients[index])) return false;
    }
    return true;
}

/* --- One setup, one delay line per channel (WP-208, WP-209) ----------------------------------- */

/* Frames filtered per call of vDSP_biquad (see ztd_biquad_process_accelerate). */
#define ZTD_BIQUAD_CHUNK 1024u

typedef struct ztd_biquad {
    uint32_t channels;
    uint32_t sections;
    uint32_t stride;          /* delay values per channel: 2 * sections + 2 */
    vDSP_biquad_Setup setup;  /* Accelerate implementation */
    float *aligned;           /* Accelerate implementation: ZTD_BIQUAD_CHUNK frames of output */
    float *coefficients;      /* native implementation: b0 b1 b2 a1 a2 per section */
    /* Per channel, as vDSP_biquad defines it: the last two inputs of the cascade, then the last
       two outputs of each section (which are the last two inputs of the next). */
    float *delay;
} ztd_biquad_t;

static uint32_t ztd_biquad_process_accelerate(void *state, const float *const *in, float *const *out,
                                              uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    if (frames == 0) return 0;
    const uint32_t count = ztd_min_u32(channels, biquad->channels);
    for (uint32_t channel = 0; channel < count; channel++) {
        float *delay = biquad->delay + (size_t)channel * biquad->stride;
        const float *source = in[channel];
        float *destination = out[channel];
        /* vDSP_biquad filters four frames at a time and lines that up with the output's address:
           into a buffer that is not 16-byte aligned it rounds differently (measured: about
           -97 dB of the peak on noise). The result must not depend on where the caller keeps its
           buffer, so a displaced block is filtered into aligned storage and copied. Either way
           the calls have the same lengths and an aligned output, so both ways give the same
           floats. */
        const bool displaced = ((uintptr_t)destination & 15u) != 0;
        for (uint32_t done = 0; done < frames;) {
            const uint32_t chunk = ztd_min_u32(frames - done, ZTD_BIQUAD_CHUNK);
            float *target = displaced ? biquad->aligned : destination + done;
            vDSP_biquad(biquad->setup, delay, source + done, 1, target, 1, chunk);
            if (displaced) memcpy(destination + done, target, (size_t)chunk * sizeof(float));
            done += chunk;
        }
    }
    ztd_flush_state(biquad->delay, biquad->channels * biquad->stride);
    return frames;
}

static uint32_t ztd_biquad_process_native(void *state, const float *const *in, float *const *out,
                                          uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    const uint32_t count = ztd_min_u32(channels, biquad->channels);
    const uint32_t sections = biquad->sections;
    const float *restrict coefficients = biquad->coefficients;
    for (uint32_t channel = 0; channel < count; channel++) {
        float *restrict delay = biquad->delay + (size_t)channel * biquad->stride;
        const float *restrict source = in[channel];
        float *restrict destination = out[channel];
        for (uint32_t frame = 0; frame < frames; frame++) {
            float value = source[frame];
            for (uint32_t section = 0; section < sections; section++) {
                const float *k = coefficients + 5 * section;
                float *x = delay + 2 * section; /* x[0] = two frames ago, x[1] = one frame ago */
                const float *y = x + 2;
                const float result = k[0] * value + k[1] * x[1] + k[2] * x[0] - k[3] * y[1] - k[4] * y[0];
                x[0] = x[1];
                x[1] = value;
                value = result;
            }
            float *last = delay + 2 * sections;
            last[0] = last[1];
            last[1] = value;
            destination[frame] = value;
        }
    }
    ztd_flush_state(biquad->delay, biquad->channels * biquad->stride);
    return frames;
}

/* New coefficients, set in place: the delay lines are not touched, so the filter keeps its
   memory (WP-209). */
static void ztd_biquad_command_accelerate(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    if (!ztd_command_sets(command, 5 * biquad->sections)) return;
    vDSP_biquad_SetCoefficientsDouble(biquad->setup, (const double *)command->values, 0, biquad->sections);
}

static void ztd_biquad_command_native(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    if (!ztd_command_sets(command, 5 * biquad->sections)) return;
    const double *values = (const double *)command->values;
    for (uint32_t index = 0; index < 5 * biquad->sections; index++) biquad->coefficients[index] = (float)values[index];
}

static void ztd_biquad_reset(void *state) ZTD_NONBLOCKING {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    memset(biquad->delay, 0, (size_t)biquad->channels * biquad->stride * sizeof(float));
}

static void ztd_biquad_destroy(void *state) {
    ztd_biquad_t *biquad = (ztd_biquad_t *)state;
    if (!biquad) return;
    if (biquad->setup) vDSP_biquad_DestroySetup(biquad->setup);
    free(biquad->aligned);
    free(biquad->coefficients);
    free(biquad->delay);
    free(biquad);
}

ztd_kernel_t ztd_biquad_create(uint32_t channels, uint32_t sections, const double *coefficients,
                               ztd_implementation_t implementation) {
    if (!ztd_biquad_arguments_are_valid(channels, sections, coefficients)) return ztd_kernel_null();
    if (implementation != ZTD_IMPLEMENTATION_NATIVE && implementation != ZTD_IMPLEMENTATION_ACCELERATE) {
        return ztd_kernel_null();
    }
    ztd_biquad_t *biquad = (ztd_biquad_t *)ztd_allocate(1, sizeof(ztd_biquad_t));
    if (!biquad) return ztd_kernel_null();
    biquad->channels = channels;
    biquad->sections = sections;
    biquad->stride = 2 * sections + 2;
    biquad->delay = (float *)ztd_allocate((size_t)channels * biquad->stride, sizeof(float));
    bool ready = biquad->delay != NULL;
    if (ready && implementation == ZTD_IMPLEMENTATION_ACCELERATE) {
        biquad->setup = ztd_may_allocate() ? vDSP_biquad_CreateSetup(coefficients, sections) : NULL;
        biquad->aligned = (float *)ztd_allocate(ZTD_BIQUAD_CHUNK, sizeof(float));
        ready = biquad->setup != NULL && biquad->aligned != NULL;
    } else if (ready) {
        biquad->coefficients = (float *)ztd_allocate((size_t)5 * sections, sizeof(float));
        ready = biquad->coefficients != NULL;
        if (ready) {
            for (uint32_t index = 0; index < 5 * sections; index++) biquad->coefficients[index] = (float)coefficients[index];
        }
    }
    if (!ready) {
        ztd_biquad_destroy(biquad);
        return ztd_kernel_null();
    }
    const bool accelerate = implementation == ZTD_IMPLEMENTATION_ACCELERATE;
    ztd_kernel_t kernel = {
        .process = accelerate ? ztd_biquad_process_accelerate : ztd_biquad_process_native,
        .command = accelerate ? ztd_biquad_command_accelerate : ztd_biquad_command_native,
        .reset = ztd_biquad_reset,
        .destroy = ztd_biquad_destroy,
        .state = biquad,
        .latency_frames = 0,
        .settling_frames = ztd_biquad_settling(coefficients, sections),
    };
    return kernel;
}

/* --- One setup for all channels (WP-210) ------------------------------------------------------- */

typedef struct ztd_biquadm {
    uint32_t channels;
    uint32_t sections;
    vDSP_biquadm_Setup setup;
    /* State hygiene, channel by channel. vDSP_biquadm keeps its delay values inside the setup,
       where they can be neither read nor flushed one by one. What can be seen is each channel's
       own input and output, and what can be set is each channel's coefficients.

       Once a channel's input and output have stayed below the floor for as many frames as the
       cascade has memory (2 * sections + 2), whatever its delay lines still hold can only decay.
       If the next block's input is quiet too, the channel is parked: it runs on coefficients of
       zero, which empty its delay lines within two frames in every form a biquad can take, and
       its output is written as exact zeros. A parked channel whose input comes back gets its
       coefficients again before that block is filtered. The other channels never notice.
       When every channel is that quiet at once, the memory is cleared as a whole. */
    uint32_t quiet_needed;
    uint32_t *quiet;       /* per channel: consecutive quiet frames up to now, saturating at `quiet_needed` */
    uint8_t *parked;       /* per channel: 1 while it runs on `zeros` */
    double *coefficients;  /* 5 * sections: what a channel that carries signal runs on */
    double *zeros;         /* 5 * sections of zero */
} ztd_biquadm_t;

/* True when no sample of the block reaches the floor. Written so that a NaN counts as loud: it
   is state the flush must not hide. */
static inline bool ztd_biquadm_is_quiet(const float *samples, uint32_t frames, float floor) ZTD_NONBLOCKING {
    for (uint32_t index = 0; index < frames; index++) {
        if (!(fabsf(samples[index]) < floor)) return false;
    }
    return true;
}

static uint32_t ztd_biquadm_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                    uint32_t frames) ZTD_NONBLOCKING {
    ztd_biquadm_t *biquad = (ztd_biquadm_t *)state;
    /* The setup filters biquad->channels channels, no fewer: with fewer buffers than that there
       is nothing safe to do. */
    if (frames == 0 || channels < biquad->channels) return 0;
    const float floor = (float)ZTD_STATE_FLOOR;

    /* Before the block: park what has been quiet long enough and stays quiet, wake what was
       parked and is given signal again. */
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        const bool is_parked = biquad->parked[channel] != 0;
        if (!is_parked && biquad->quiet[channel] < biquad->quiet_needed) continue;
        const bool silent = ztd_biquadm_is_quiet(in[channel], frames, floor);
        if (silent && !is_parked) {
            vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->zeros, 0, channel, biquad->sections, 1);
            biquad->parked[channel] = 1;
        } else if (!silent && is_parked) {
            vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->coefficients, 0, channel, biquad->sections, 1);
            biquad->parked[channel] = 0;
            biquad->quiet[channel] = 0;
        }
    }

    vDSP_biquadm(biquad->setup, (const float **)in, 1, (float **)out, 1, frames);

    const uint32_t scan = ztd_min_u32(frames, biquad->quiet_needed);
    bool all_quiet = true;
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) {
            /* Nothing comes out of a parked channel, not even what its memory held when it was
               parked. */
            memset(out[channel], 0, (size_t)frames * sizeof(float));
            continue;
        }
        const float *x = in[channel] + frames, *y = out[channel] + frames;
        uint32_t trailing = scan; /* quiet frames at the end of this block */
        for (uint32_t back = 1; back <= scan; back++) {
            if (!(fabsf(x[-(ptrdiff_t)back]) < floor) || !(fabsf(y[-(ptrdiff_t)back]) < floor)) {
                trailing = back - 1;
                break;
            }
        }
        if (trailing == scan && frames < biquad->quiet_needed) {
            biquad->quiet[channel] = ztd_min_u32(biquad->quiet[channel] + frames, biquad->quiet_needed);
        } else {
            biquad->quiet[channel] = trailing;
        }
        if (biquad->quiet[channel] < biquad->quiet_needed) all_quiet = false;
    }
    if (all_quiet) vDSP_biquadm_ResetState(biquad->setup);
    return frames;
}

static void ztd_biquadm_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_biquadm_t *biquad = (ztd_biquadm_t *)state;
    if (!ztd_command_sets(command, 5 * biquad->sections)) return;
    memcpy(biquad->coefficients, command->values, (size_t)5 * biquad->sections * sizeof(double));
    /* One channel at a time: with a single channel the layout vDSP expects is the plain list of
       sections the command carries. A parked channel takes the new values when it wakes. */
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) continue;
        vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->coefficients, 0, channel, biquad->sections, 1);
    }
}

static void ztd_biquadm_reset(void *state) ZTD_NONBLOCKING {
    ztd_biquadm_t *biquad = (ztd_biquadm_t *)state;
    vDSP_biquadm_ResetState(biquad->setup);
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) {
            vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->coefficients, 0, channel, biquad->sections, 1);
            biquad->parked[channel] = 0;
        }
        biquad->quiet[channel] = 0;
    }
}

static void ztd_biquadm_destroy(void *state) {
    ztd_biquadm_t *biquad = (ztd_biquadm_t *)state;
    if (!biquad) return;
    if (biquad->setup) vDSP_biquadm_DestroySetup(biquad->setup);
    free(biquad->quiet);
    free(biquad->parked);
    free(biquad->coefficients);
    free(biquad->zeros);
    free(biquad);
}

ztd_kernel_t ztd_biquadm_create(uint32_t channels, uint32_t sections, const double *coefficients) {
    if (!ztd_biquad_arguments_are_valid(channels, sections, coefficients)) return ztd_kernel_null();
    ztd_biquadm_t *biquad = (ztd_biquadm_t *)ztd_allocate(1, sizeof(ztd_biquadm_t));
    /* vDSP wants every section's coefficients once per channel: section 0 for all channels, then
       section 1 for all channels, and so on. */
    double *expanded = (double *)ztd_allocate((size_t)5 * sections * channels, sizeof(double));
    if (biquad && expanded) {
        for (uint32_t section = 0; section < sections; section++) {
            for (uint32_t channel = 0; channel < channels; channel++) {
                memcpy(expanded + 5 * ((size_t)section * channels + channel), coefficients + 5 * section,
                       5 * sizeof(double));
            }
        }
        biquad->setup = ztd_may_allocate() ? vDSP_biquadm_CreateSetup(expanded, sections, channels) : NULL;
    }
    free(expanded);
    if (biquad && biquad->setup) {
        biquad->quiet = (uint32_t *)ztd_allocate(channels, sizeof(uint32_t));
        biquad->parked = (uint8_t *)ztd_allocate(channels, sizeof(uint8_t));
        biquad->coefficients = (double *)ztd_allocate((size_t)5 * sections, sizeof(double));
        biquad->zeros = (double *)ztd_allocate((size_t)5 * sections, sizeof(double));
    }
    if (!biquad || !biquad->setup || !biquad->quiet || !biquad->parked || !biquad->coefficients || !biquad->zeros) {
        ztd_biquadm_destroy(biquad);
        return ztd_kernel_null();
    }
    memcpy(biquad->coefficients, coefficients, (size_t)5 * sections * sizeof(double));
    biquad->channels = channels;
    biquad->sections = sections;
    biquad->quiet_needed = 2 * sections + 2;
    ztd_kernel_t kernel = {
        .process = ztd_biquadm_process,
        .command = ztd_biquadm_command,
        .reset = ztd_biquadm_reset,
        .destroy = ztd_biquadm_destroy,
        .state = biquad,
        .latency_frames = 0,
        .settling_frames = ztd_biquad_settling(coefficients, sections),
    };
    return kernel;
}
