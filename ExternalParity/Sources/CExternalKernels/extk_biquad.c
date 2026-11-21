#include "CExternalKernels.h"

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

/* snippet:begin biquad-vdsp */
#include "ztd_kernels.h" /* ztd_flush_state, ztd_flush_state_double: the toolkit's state hygiene (RT-6) */
/* vDSP's declarations carry no `nonblocking` attribute, so clang rejects a call to them from a
   non-blocking function. ztd_vdsp.h, a public header of ZTronDSP, is the audited allow-list:
   it re-declares with the attribute the entry points ZTronDSP's own kernels call, among them
   the five this kernel calls (vDSP_biquad and vDSP_biquadm, their coefficient setters, the
   reset of vDSP_biquadm), each with the audit that holds the claim. The allocation audit of
   this suite runs all five once more, in this kernel. */
#include "ztd_vdsp.h"
/* snippet:end biquad-vdsp */

/* The biquad cascade of the external parity suite (EXT-4): a kernel of the caller's own on the
   ABI of ztd_kernel.h. Everything a plan calls on the analysis thread is ZTD_NONBLOCKING, and
   this target turns function-effect warnings into errors, so an allocation or a call to a
   function that may block does not build (RT-1, RT-7 layer 1). */

/* Every product and every sum of the two loops written here is rounded on its own, in the order
   written. */
#pragma STDC FP_CONTRACT OFF

/* The largest channel or section count the constructor accepts: far from any overflow. */
#define EXTK_LIMIT ((uint32_t)1 << 24)
/* Frames filtered per call of vDSP_biquad. */
#define EXTK_CHUNK 1024u
#define EXTK_SETTLING_CAP ((uint32_t)1 << 24)

typedef struct extk_biquad {
    uint32_t channels;
    uint32_t sections;
    /* Single precision on vDSP_biquad. */
    uint32_t stride;         /* delay values per channel: 2 * sections + 2 */
    vDSP_biquad_Setup setup;
    float *delay;            /* per channel, as vDSP_biquad keeps it */
    float *aligned;          /* EXTK_CHUNK frames of output for a caller's buffer that is displaced */
    /* Single precision in a C loop. */
    float *taps;             /* b0 b1 b2 a1 a2 per section */
    float *history;          /* per channel and section: x[n−1], x[n−2], y[n−1], y[n−2] */
    /* Double precision. */
    double *coefficients;    /* b0 b1 b2 a1 a2 per section */
    double *memory;          /* s1 s2 per section, per channel */
} extk_biquad_t;

/* Zero-filled storage on a cache line. Writing the zeros touches every page, so the analysis
   thread takes no first-touch fault. Control context. */
static void *extk_allocate(size_t count, size_t size) {
    size_t bytes = count * size;
    if (bytes < 64) bytes = 64;
    void *storage = NULL;
    if (posix_memalign(&storage, 64, bytes) != 0) return NULL;
    memset(storage, 0, bytes);
    return storage;
}

static ztd_kernel_t extk_null(void) {
    ztd_kernel_t kernel;
    memset(&kernel, 0, sizeof kernel);
    return kernel;
}

uint32_t extk_biquad_settling(const double *coefficients, uint32_t sections) {
    if (!coefficients) return 0;
    double radius = 0.0;
    for (uint32_t section = 0; section < sections; section++) {
        const double a1 = coefficients[5 * section + 3], a2 = coefficients[5 * section + 4];
        const double discriminant = a1 * a1 - 4.0 * a2;
        double largest;
        if (discriminant < 0.0) {
            largest = sqrt(a2); /* a conjugate pair: the square of its radius is a2 */
        } else {
            const double root = sqrt(discriminant);
            largest = fmax(fabs(-a1 + root), fabs(-a1 - root)) / 2.0;
        }
        if (!(largest <= radius)) radius = largest; /* a NaN is kept and caps the result */
    }
    if (radius == 0.0) return 0;
    if (!(radius < 1.0)) return EXTK_SETTLING_CAP;
    const double frames = ceil(log(1e-5) / log(radius)); /* radius^frames has fallen by 100 dB */
    return frames < (double)EXTK_SETTLING_CAP ? (uint32_t)frames : EXTK_SETTLING_CAP;
}

/* --- Single precision: vDSP_biquad ------------------------------------------------------------ */

static uint32_t extk_biquad_process_single(void *state, const float *const *in, float *const *out,
                                           uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (frames == 0) return 0;
    const uint32_t count = channels < biquad->channels ? channels : biquad->channels;
    for (uint32_t channel = 0; channel < count; channel++) {
        float *delay = biquad->delay + (size_t)channel * biquad->stride;
        const float *source = in[channel];
        float *destination = out[channel];
        /* vDSP_biquad rounds differently into an output that is not 16-byte aligned. What the
           kernel writes must not depend on where the caller keeps its buffer, so a displaced
           block is filtered into aligned storage and copied. */
        const bool displaced = ((uintptr_t)destination & 15u) != 0;
        uint32_t done = 0;
        while (done < frames) {
            const uint32_t chunk = frames - done < EXTK_CHUNK ? frames - done : EXTK_CHUNK;
            float *target = displaced ? biquad->aligned : destination + done;
            vDSP_biquad(biquad->setup, delay, source + done, 1, target, 1, chunk);
            if (displaced) memcpy(destination + done, target, (size_t)chunk * sizeof(float));
            done += chunk;
        }
    }
    /* RT-6: no state value below the floor is left behind at the end of a block. */
    ztd_flush_state(biquad->delay, biquad->channels * biquad->stride);
    return frames;
}

static void extk_biquad_command_single(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (!command || command->kind != ZTD_COMMAND_SET_VALUES || !command->values) return;
    if (command->count != 5 * biquad->sections) return;
    /* Set in place: the delay lines are not touched, so the filter keeps its memory. */
    vDSP_biquad_SetCoefficientsDouble(biquad->setup, (const double *)command->values, 0, biquad->sections);
}

static void extk_biquad_reset_single(void *state) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    memset(biquad->delay, 0, (size_t)biquad->channels * biquad->stride * sizeof(float));
}

/* --- Single precision: the recurrence in a C loop --------------------------------------------- */

static uint32_t extk_biquad_process_loop(void *state, const float *const *in, float *const *out,
                                         uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (frames == 0) return 0;
    const uint32_t count = channels < biquad->channels ? channels : biquad->channels;
    const uint32_t sections = biquad->sections;
    const float *restrict taps = biquad->taps;
    for (uint32_t channel = 0; channel < count; channel++) {
        float *restrict history = biquad->history + (size_t)channel * 4 * sections;
        const float *restrict source = in[channel];
        float *restrict destination = out[channel];
        for (uint32_t frame = 0; frame < frames; frame++) {
            float value = source[frame];
            for (uint32_t section = 0; section < sections; section++) {
                const float *k = taps + 5 * section;
                float *h = history + 4 * section;
                const float result = k[0] * value + k[1] * h[0] + k[2] * h[1] - k[3] * h[2] - k[4] * h[3];
                h[1] = h[0];
                h[0] = value;
                h[3] = h[2];
                h[2] = result;
                value = result;
            }
            destination[frame] = value;
        }
    }
    ztd_flush_state(biquad->history, biquad->channels * 4 * sections);
    return frames;
}

static void extk_biquad_command_loop(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (!command || command->kind != ZTD_COMMAND_SET_VALUES || !command->values) return;
    if (command->count != 5 * biquad->sections) return;
    const double *values = (const double *)command->values;
    for (uint32_t index = 0; index < 5 * biquad->sections; index++) biquad->taps[index] = (float)values[index];
}

static void extk_biquad_reset_loop(void *state) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    memset(biquad->history, 0, (size_t)biquad->channels * 4 * biquad->sections * sizeof(float));
}

/* --- Double precision: transposed direct form II ---------------------------------------------- */

static uint32_t extk_biquad_process_double(void *state, const float *const *in, float *const *out,
                                           uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (frames == 0) return 0;
    const uint32_t count = channels < biquad->channels ? channels : biquad->channels;
    const uint32_t sections = biquad->sections;
    const double *restrict coefficients = biquad->coefficients;
    for (uint32_t channel = 0; channel < count; channel++) {
        double *restrict memory = biquad->memory + (size_t)channel * 2 * sections;
        const float *restrict source = in[channel];
        float *restrict destination = out[channel];
        for (uint32_t frame = 0; frame < frames; frame++) {
            double value = (double)source[frame];
            for (uint32_t section = 0; section < sections; section++) {
                const double *k = coefficients + 5 * section;
                double *s = memory + 2 * section;
                const double result = k[0] * value + s[0];
                s[0] = k[1] * value - k[3] * result + s[1];
                s[1] = k[2] * value - k[4] * result;
                value = result;
            }
            destination[frame] = (float)value;
        }
    }
    ztd_flush_state_double(biquad->memory, biquad->channels * 2 * sections);
    return frames;
}

/* snippet:begin biquad-command */
/* The values of the description, as the engine sends them at a block boundary: `count` doubles
   at `values`, memory the engine owns. The coefficients are replaced; the memory is kept. A
   command of another kind or count, or with no payload, is not for this kernel. */
static void extk_biquad_command_double(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (!command || command->kind != ZTD_COMMAND_SET_VALUES || !command->values) return;
    if (command->count != 5 * biquad->sections) return;
    memcpy(biquad->coefficients, command->values, (size_t)5 * biquad->sections * sizeof(double));
}
/* snippet:end biquad-command */

static void extk_biquad_reset_double(void *state) ZTD_NONBLOCKING {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    memset(biquad->memory, 0, (size_t)biquad->channels * 2 * biquad->sections * sizeof(double));
}

/* --- Single precision, from three channels up: vDSP_biquadm ----------------------------------- */

/* One setup for all channels, where the stock cascade runs on one too: the same routine, so the
   same floats, provided the memory is kept clean at the same frames.

   vDSP_biquadm keeps its delay values inside the setup, where they can be neither read nor
   flushed one by one. State hygiene (RT-6) therefore works on what can be seen, each channel's
   input and output, and on what can be set, each channel's coefficients. A channel whose input
   and output have stayed below the floor for 2·sections + 2 frames, the length of the cascade's
   memory, and whose next block is quiet too, is parked: it runs on coefficients of zero, which
   empty its memory, and its output is written as zeros. It gets its coefficients back before
   the first block that carries signal again. When every channel is that quiet at once, the
   memory is cleared as a whole. */
typedef struct extk_biquadm {
    uint32_t channels;
    uint32_t sections;
    vDSP_biquadm_Setup setup;
    uint32_t quiet_needed;   /* 2 * sections + 2 */
    uint32_t *quiet;         /* per channel: consecutive quiet frames up to now, at most quiet_needed */
    uint8_t *parked;         /* per channel: 1 while it runs on `zeros` */
    double *coefficients;    /* 5 * sections: what a channel that carries signal runs on */
    double *zeros;           /* 5 * sections of zero */
} extk_biquadm_t;

/* True when no sample reaches the floor. A NaN counts as loud. */
static inline bool extk_is_quiet(const float *samples, uint32_t frames, float floor) ZTD_NONBLOCKING {
    for (uint32_t index = 0; index < frames; index++) {
        if (!(fabsf(samples[index]) < floor)) return false;
    }
    return true;
}

static uint32_t extk_biquadm_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                     uint32_t frames) ZTD_NONBLOCKING {
    extk_biquadm_t *biquad = (extk_biquadm_t *)state;
    /* The setup filters all its channels or none. */
    if (frames == 0 || channels < biquad->channels) return 0;
    const float floor = (float)ZTD_STATE_FLOOR;

    /* Before the block: park what has been quiet long enough and stays quiet; wake what was
       parked and is given signal again. */
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        const bool is_parked = biquad->parked[channel] != 0;
        if (!is_parked && biquad->quiet[channel] < biquad->quiet_needed) continue;
        const bool silent = extk_is_quiet(in[channel], frames, floor);
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

    /* After the block: how long each channel has been quiet at its end. */
    const uint32_t scan = frames < biquad->quiet_needed ? frames : biquad->quiet_needed;
    bool all_quiet = true;
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) {
            memset(out[channel], 0, (size_t)frames * sizeof(float));
            continue;
        }
        const float *x = in[channel] + frames, *y = out[channel] + frames;
        uint32_t trailing = scan;
        for (uint32_t back = 1; back <= scan; back++) {
            if (!(fabsf(x[-(ptrdiff_t)back]) < floor) || !(fabsf(y[-(ptrdiff_t)back]) < floor)) {
                trailing = back - 1;
                break;
            }
        }
        if (trailing == scan && frames < biquad->quiet_needed) {
            const uint32_t sum = biquad->quiet[channel] + frames;
            biquad->quiet[channel] = sum < biquad->quiet_needed ? sum : biquad->quiet_needed;
        } else {
            biquad->quiet[channel] = trailing;
        }
        if (biquad->quiet[channel] < biquad->quiet_needed) all_quiet = false;
    }
    if (all_quiet) vDSP_biquadm_ResetState(biquad->setup);
    return frames;
}

static void extk_biquadm_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    extk_biquadm_t *biquad = (extk_biquadm_t *)state;
    if (!command || command->kind != ZTD_COMMAND_SET_VALUES || !command->values) return;
    if (command->count != 5 * biquad->sections) return;
    memcpy(biquad->coefficients, command->values, (size_t)5 * biquad->sections * sizeof(double));
    /* One channel at a time: for a single channel the layout vDSP expects is the plain list of
       sections. A parked channel takes the new values when it wakes. */
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) continue;
        vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->coefficients, 0, channel, biquad->sections, 1);
    }
}

static void extk_biquadm_reset(void *state) ZTD_NONBLOCKING {
    extk_biquadm_t *biquad = (extk_biquadm_t *)state;
    vDSP_biquadm_ResetState(biquad->setup);
    for (uint32_t channel = 0; channel < biquad->channels; channel++) {
        if (biquad->parked[channel]) {
            vDSP_biquadm_SetCoefficientsDouble(biquad->setup, biquad->coefficients, 0, channel, biquad->sections, 1);
            biquad->parked[channel] = 0;
        }
        biquad->quiet[channel] = 0;
    }
}

/* Control context. */
static void extk_biquadm_destroy(void *state) {
    extk_biquadm_t *biquad = (extk_biquadm_t *)state;
    if (!biquad) return;
    if (biquad->setup) vDSP_biquadm_DestroySetup(biquad->setup);
    free(biquad->quiet);
    free(biquad->parked);
    free(biquad->coefficients);
    free(biquad->zeros);
    free(biquad);
}

/* Control context. The arguments have been checked by extk_biquad_create. */
static ztd_kernel_t extk_biquadm_create(uint32_t channels, uint32_t sections, const double *coefficients) {
    extk_biquadm_t *biquad = (extk_biquadm_t *)extk_allocate(1, sizeof(extk_biquadm_t));
    /* vDSP wants every section's coefficients once per channel: section 0 for all channels,
       then section 1 for all channels, and so on. */
    double *expanded = (double *)extk_allocate((size_t)5 * sections * channels, sizeof(double));
    if (biquad && expanded) {
        for (uint32_t section = 0; section < sections; section++) {
            for (uint32_t channel = 0; channel < channels; channel++) {
                memcpy(expanded + 5 * ((size_t)section * channels + channel), coefficients + 5 * section, 5 * sizeof(double));
            }
        }
        biquad->setup = vDSP_biquadm_CreateSetup(expanded, sections, channels);
    }
    free(expanded);
    if (biquad && biquad->setup) {
        biquad->quiet = (uint32_t *)extk_allocate(channels, sizeof(uint32_t));
        biquad->parked = (uint8_t *)extk_allocate(channels, sizeof(uint8_t));
        biquad->coefficients = (double *)extk_allocate((size_t)5 * sections, sizeof(double));
        biquad->zeros = (double *)extk_allocate((size_t)5 * sections, sizeof(double));
    }
    if (!biquad || !biquad->setup || !biquad->quiet || !biquad->parked || !biquad->coefficients || !biquad->zeros) {
        extk_biquadm_destroy(biquad);
        return extk_null();
    }
    memcpy(biquad->coefficients, coefficients, (size_t)5 * sections * sizeof(double));
    biquad->channels = channels;
    biquad->sections = sections;
    biquad->quiet_needed = 2 * sections + 2;
    ztd_kernel_t kernel = extk_null();
    kernel.process = extk_biquadm_process;
    kernel.command = extk_biquadm_command;
    kernel.reset = extk_biquadm_reset;
    kernel.destroy = extk_biquadm_destroy;
    kernel.state = biquad;
    kernel.latency_frames = 0;
    kernel.settling_frames = extk_biquad_settling(coefficients, sections);
    return kernel;
}

/* --- Creation and destruction: control context ------------------------------------------------ */

static void extk_biquad_destroy(void *state) {
    extk_biquad_t *biquad = (extk_biquad_t *)state;
    if (!biquad) return;
    if (biquad->setup) vDSP_biquad_DestroySetup(biquad->setup);
    free(biquad->delay);
    free(biquad->aligned);
    free(biquad->taps);
    free(biquad->history);
    free(biquad->coefficients);
    free(biquad->memory);
    free(biquad);
}

ztd_kernel_t extk_biquad_create(uint32_t channels, uint32_t sections, const double *coefficients,
                                bool double_precision, ztd_implementation_t implementation) {
    if (channels == 0 || channels > EXTK_LIMIT || sections == 0 || sections > EXTK_LIMIT || !coefficients) {
        return extk_null();
    }
    if (implementation != ZTD_IMPLEMENTATION_NATIVE && implementation != ZTD_IMPLEMENTATION_ACCELERATE) return extk_null();
    if ((uint64_t)channels * (4 * (uint64_t)sections + 2) > ((uint64_t)1 << 28)) return extk_null();
    for (uint32_t index = 0; index < 5 * sections; index++) {
        if (!isfinite(coefficients[index])) return extk_null();
    }
    /* One setup for all channels pays from three channels up: where the stock cascade changes
       routine, this one does. */
    if (!double_precision && implementation == ZTD_IMPLEMENTATION_ACCELERATE && channels > 2) {
        return extk_biquadm_create(channels, sections, coefficients);
    }
    extk_biquad_t *biquad = (extk_biquad_t *)extk_allocate(1, sizeof(extk_biquad_t));
    if (!biquad) return extk_null();
    biquad->channels = channels;
    biquad->sections = sections;
    ztd_kernel_t kernel = extk_null();
    bool ready;
    if (double_precision) {
        biquad->coefficients = (double *)extk_allocate((size_t)5 * sections, sizeof(double));
        biquad->memory = (double *)extk_allocate((size_t)channels * 2 * sections, sizeof(double));
        ready = biquad->coefficients != NULL && biquad->memory != NULL;
        if (ready) memcpy(biquad->coefficients, coefficients, (size_t)5 * sections * sizeof(double));
        kernel.process = extk_biquad_process_double;
        kernel.command = extk_biquad_command_double;
        kernel.reset = extk_biquad_reset_double;
    } else if (implementation == ZTD_IMPLEMENTATION_ACCELERATE) {
        biquad->stride = 2 * sections + 2;
        biquad->delay = (float *)extk_allocate((size_t)channels * biquad->stride, sizeof(float));
        biquad->aligned = (float *)extk_allocate(EXTK_CHUNK, sizeof(float));
        biquad->setup = vDSP_biquad_CreateSetup(coefficients, sections);
        ready = biquad->delay != NULL && biquad->aligned != NULL && biquad->setup != NULL;
        kernel.process = extk_biquad_process_single;
        kernel.command = extk_biquad_command_single;
        kernel.reset = extk_biquad_reset_single;
    } else {
        biquad->taps = (float *)extk_allocate((size_t)5 * sections, sizeof(float));
        biquad->history = (float *)extk_allocate((size_t)channels * 4 * sections, sizeof(float));
        ready = biquad->taps != NULL && biquad->history != NULL;
        if (ready) {
            for (uint32_t index = 0; index < 5 * sections; index++) biquad->taps[index] = (float)coefficients[index];
        }
        kernel.process = extk_biquad_process_loop;
        kernel.command = extk_biquad_command_loop;
        kernel.reset = extk_biquad_reset_loop;
    }
    if (!ready) {
        extk_biquad_destroy(biquad);
        return extk_null();
    }
    kernel.destroy = extk_biquad_destroy;
    kernel.state = biquad;
    kernel.latency_frames = 0;
    kernel.settling_frames = extk_biquad_settling(coefficients, sections);
    return kernel;
}
