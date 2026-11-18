#include <math.h>

#include "ztd_internal.h"

/* The alpha-beta tracker (WP-218, §6.3.6). Per sample z, with time step dt:

       p = x + dt * v          the predicted position
       r = z - p               the residual
       x = p + alpha * r
       v = v + (beta / dt) * r

   The two states are kept in double precision: beta / dt is large (beta times the sample rate),
   and in Float32 the recurrence would drift from its definition by more than the 1e-6 the
   package is held to. Samples are Float32 on the way in and on the way out. */

/* Every product and sum is rounded on its own, in the order written. */
#pragma STDC FP_CONTRACT OFF

typedef struct ztd_alpha_beta {
    uint32_t channels;
    bool output_velocity;
    double alpha;
    double step;           /* dt */
    double gain;           /* beta / dt */
    double initial[2];     /* position, velocity */
    double *state;         /* position, velocity per channel */
} ztd_alpha_beta_t;

static uint32_t ztd_alpha_beta_process(void *state, const float *const *in, float *const *out,
                                       uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_alpha_beta_t *tracker = (ztd_alpha_beta_t *)state;
    const uint32_t count = ztd_min_u32(channels, tracker->channels);
    const double alpha = tracker->alpha, step = tracker->step, gain = tracker->gain;
    for (uint32_t channel = 0; channel < count; channel++) {
        double *memory = tracker->state + 2 * (size_t)channel;
        double position = memory[0], velocity = memory[1];
        const float *restrict source = in[channel];
        float *restrict destination = out[channel];
        if (tracker->output_velocity) {
            for (uint32_t frame = 0; frame < frames; frame++) {
                const double predicted = position + step * velocity;
                const double residual = (double)source[frame] - predicted;
                position = predicted + alpha * residual;
                velocity = velocity + gain * residual;
                destination[frame] = (float)velocity;
            }
        } else {
            for (uint32_t frame = 0; frame < frames; frame++) {
                const double predicted = position + step * velocity;
                const double residual = (double)source[frame] - predicted;
                position = predicted + alpha * residual;
                velocity = velocity + gain * residual;
                destination[frame] = (float)position;
            }
        }
        memory[0] = position;
        memory[1] = velocity;
    }
    ztd_flush_state_double(tracker->state, 2 * tracker->channels);
    return frames;
}

static void ztd_alpha_beta_reset(void *state) ZTD_NONBLOCKING {
    ztd_alpha_beta_t *tracker = (ztd_alpha_beta_t *)state;
    for (uint32_t channel = 0; channel < tracker->channels; channel++) {
        tracker->state[2 * (size_t)channel] = tracker->initial[0];
        tracker->state[2 * (size_t)channel + 1] = tracker->initial[1];
    }
}

static void ztd_alpha_beta_destroy(void *state) {
    ztd_alpha_beta_t *tracker = (ztd_alpha_beta_t *)state;
    if (!tracker) return;
    free(tracker->state);
    free(tracker);
}

ztd_kernel_t ztd_alpha_beta_create(uint32_t channels, float alpha, float beta, float time_step,
                                   float initial_position, float initial_velocity, bool output_velocity) {
    /* A time step that is not a positive, finite number has no beta / dt. */
    if (channels == 0 || channels > ZTD_LIMIT || !isfinite(alpha) || !isfinite(beta) || !isfinite(time_step) ||
        !(time_step > 0.0f) || !isfinite(initial_position) || !isfinite(initial_velocity)) {
        return ztd_kernel_null();
    }
    ztd_alpha_beta_t *tracker = (ztd_alpha_beta_t *)ztd_allocate(1, sizeof(ztd_alpha_beta_t));
    if (!tracker) return ztd_kernel_null();
    tracker->channels = channels;
    tracker->output_velocity = output_velocity;
    tracker->alpha = (double)alpha;
    tracker->step = (double)time_step;
    tracker->gain = (double)beta / (double)time_step;
    tracker->initial[0] = (double)initial_position;
    tracker->initial[1] = (double)initial_velocity;
    tracker->state = (double *)ztd_allocate(2 * (size_t)channels, sizeof(double));
    if (!tracker->state) {
        ztd_alpha_beta_destroy(tracker);
        return ztd_kernel_null();
    }
    ztd_alpha_beta_reset(tracker);
    ztd_kernel_t kernel = {
        .process = ztd_alpha_beta_process,
        .command = NULL,
        .reset = ztd_alpha_beta_reset,
        .destroy = ztd_alpha_beta_destroy,
        .state = tracker,
        .latency_frames = 0,
        .settling_frames = 0,
    };
    return kernel;
}
