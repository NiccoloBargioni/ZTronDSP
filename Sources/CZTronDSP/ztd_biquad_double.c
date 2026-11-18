#include "ztd_internal.h"

/* The double-precision biquad cascade (WP-211, REAL-3): the package's own kernel, because
   vDSP's double-precision setup has no coefficient setter at the deployment floor (E-08).

   Transposed direct form II, per section, with double coefficients and double state:

       y  = b0 * x + s1
       s1 = b1 * x - a1 * y + s2
       s2 = b2 * x - a2 * y

   Samples are Float32 on the way in and on the way out; everything between is double, so a
   cascade whose poles sit within 1e-3 of z = 1 keeps about nine more digits than Float32 has to
   lose. New coefficients replace the old ones at a block boundary and the state stays. */

/* Every product and sum is rounded on its own, in the order written: a scalar reference in any
   language reproduces the kernel bit for bit. */
#pragma STDC FP_CONTRACT OFF

typedef struct ztd_biquad_double {
    uint32_t channels;
    uint32_t sections;
    double *coefficients; /* b0 b1 b2 a1 a2 per section */
    double *state;        /* s1 s2 per section, per channel */
} ztd_biquad_double_t;

static uint32_t ztd_biquad_double_process(void *state, const float *const *in, float *const *out,
                                          uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_biquad_double_t *biquad = (ztd_biquad_double_t *)state;
    const uint32_t count = ztd_min_u32(channels, biquad->channels);
    const uint32_t sections = biquad->sections;
    const double *restrict coefficients = biquad->coefficients;
    for (uint32_t channel = 0; channel < count; channel++) {
        double *restrict memory = biquad->state + (size_t)channel * 2 * sections;
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
    ztd_flush_state_double(biquad->state, biquad->channels * 2 * sections);
    return frames;
}

/* The exchange (REAL-3): the new coefficients are copied in, the state is kept. */
static void ztd_biquad_double_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_biquad_double_t *biquad = (ztd_biquad_double_t *)state;
    if (!ztd_command_sets(command, 5 * biquad->sections)) return;
    memcpy(biquad->coefficients, command->values, (size_t)5 * biquad->sections * sizeof(double));
}

static void ztd_biquad_double_reset(void *state) ZTD_NONBLOCKING {
    ztd_biquad_double_t *biquad = (ztd_biquad_double_t *)state;
    memset(biquad->state, 0, (size_t)biquad->channels * 2 * biquad->sections * sizeof(double));
}

static void ztd_biquad_double_destroy(void *state) {
    ztd_biquad_double_t *biquad = (ztd_biquad_double_t *)state;
    if (!biquad) return;
    free(biquad->coefficients);
    free(biquad->state);
    free(biquad);
}

ztd_kernel_t ztd_biquad_double_create(uint32_t channels, uint32_t sections, const double *coefficients) {
    if (!ztd_biquad_arguments_are_valid(channels, sections, coefficients)) return ztd_kernel_null();
    ztd_biquad_double_t *biquad = (ztd_biquad_double_t *)ztd_allocate(1, sizeof(ztd_biquad_double_t));
    if (!biquad) return ztd_kernel_null();
    biquad->channels = channels;
    biquad->sections = sections;
    biquad->coefficients = (double *)ztd_allocate((size_t)5 * sections, sizeof(double));
    biquad->state = (double *)ztd_allocate((size_t)channels * 2 * sections, sizeof(double));
    if (!biquad->coefficients || !biquad->state) {
        ztd_biquad_double_destroy(biquad);
        return ztd_kernel_null();
    }
    memcpy(biquad->coefficients, coefficients, (size_t)5 * sections * sizeof(double));
    ztd_kernel_t kernel = {
        .process = ztd_biquad_double_process,
        .command = ztd_biquad_double_command,
        .reset = ztd_biquad_double_reset,
        .destroy = ztd_biquad_double_destroy,
        .state = biquad,
        .latency_frames = 0,
        .settling_frames = ztd_biquad_settling(coefficients, sections),
    };
    return kernel;
}
