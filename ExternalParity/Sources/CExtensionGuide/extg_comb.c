#include "CExtensionGuide.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

/* The feedback comb filter of the extension guide: a kernel of the caller's own on the ABI of
   ztd_kernel.h. What a plan calls on the analysis thread is ZTD_NONBLOCKING, and this target
   turns function-effect warnings into errors, so an allocation or a call that may block does
   not build (RT-1, RT-7 layer 1). */

/* snippet:begin comb-kernel */
typedef struct extg_comb {
    uint32_t channels;
    uint32_t delay;    /* frames between a sample and its echo */
    uint32_t position; /* where y[n − delay] sits in every ring */
    float feedback;
    float *ring;       /* per channel: the last `delay` outputs */
} extg_comb_t;

static uint32_t extg_comb_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                  uint32_t frames) ZTD_NONBLOCKING {
    extg_comb_t *comb = (extg_comb_t *)state;
    const uint32_t count = channels < comb->channels ? channels : comb->channels;
    const float floor = (float)ZTD_STATE_FLOOR;
    for (uint32_t channel = 0; channel < count; channel++) {
        float *ring = comb->ring + (size_t)channel * comb->delay;
        const float *source = in[channel];
        float *destination = out[channel];
        uint32_t position = comb->position;
        for (uint32_t frame = 0; frame < frames; frame++) {
            const float value = source[frame] + comb->feedback * ring[position];
            /* RT-6: an echo that has decayed below the floor enters the ring as zero, so the
               kernel never leaves denormal state behind. */
            ring[position] = (value < floor && value > -floor) ? 0.0f : value;
            destination[frame] = value;
            position = position + 1 == comb->delay ? 0 : position + 1;
        }
    }
    comb->position = (uint32_t)(((uint64_t)comb->position + frames) % comb->delay);
    return frames;
}

/* A cold start (ACT-10): the feedback is kept, the echoes are not. */
static void extg_comb_reset(void *state) ZTD_NONBLOCKING {
    extg_comb_t *comb = (extg_comb_t *)state;
    memset(comb->ring, 0, (size_t)comb->channels * comb->delay * sizeof(float));
    comb->position = 0;
}

/* Control context: the only place the kernel frees. */
static void extg_comb_destroy(void *state) {
    extg_comb_t *comb = (extg_comb_t *)state;
    if (!comb) return;
    free(comb->ring);
    free(comb);
}

ztd_kernel_t extg_comb_create(uint32_t channels, uint32_t delay_frames, float feedback) {
    ztd_kernel_t kernel;
    memset(&kernel, 0, sizeof kernel); /* `process` is NULL: what a failed creation returns */
    const uint32_t limit = (uint32_t)1 << 24;
    if (channels == 0 || channels > limit || delay_frames == 0 || delay_frames > limit) return kernel;
    if (!isfinite(feedback) || !(fabsf(feedback) < 1.0f)) return kernel;

    extg_comb_t *comb = (extg_comb_t *)calloc(1, sizeof(extg_comb_t));
    if (!comb) return kernel;
    comb->channels = channels;
    comb->delay = delay_frames;
    comb->feedback = feedback;
    /* calloc hands out zeros, and the analysis thread must not take the first-touch fault of a
       page: the ring is written once here. */
    comb->ring = (float *)calloc((size_t)channels * delay_frames, sizeof(float));
    if (!comb->ring) {
        free(comb);
        return kernel;
    }
    memset(comb->ring, 0, (size_t)channels * delay_frames * sizeof(float));

    /* The echoes decay by |feedback| per `delay_frames`: after `echoes` of them they are 100 dB down. */
    double settling = 0.0;
    if (feedback != 0.0f) settling = ceil(log(1e-5) / log(fabs((double)feedback))) * (double)delay_frames;

    /* `command` stays NULL: the engine sends no value to a kernel of the caller's own. */
    kernel.process = extg_comb_process;
    kernel.reset = extg_comb_reset;
    kernel.destroy = extg_comb_destroy;
    kernel.state = comb;
    kernel.latency_frames = 0;
    kernel.settling_frames = settling < (double)limit ? (uint32_t)settling : limit;
    return kernel;
}
/* snippet:end comb-kernel */
