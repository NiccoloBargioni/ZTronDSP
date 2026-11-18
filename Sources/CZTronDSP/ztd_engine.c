#include "ztd_engine.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>

#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* --- Gain cascade --------------------------------------------------------------------------- */

typedef struct ztd_gain_stage {
    float current;      /* the factor now */
    float target;       /* the factor a ramp is moving to */
    float increment;    /* per frame while ramping */
    uint32_t remaining; /* frames of ramp left */
} ztd_gain_stage_t;

typedef struct ztd_gain_cascade {
    uint32_t count;
    uint32_t ramp_frames;
    ztd_gain_stage_t *stages;
    void (*apply)(const float *in, float *out, float factor, uint32_t frames) ZTD_NONBLOCKING;
} ztd_gain_cascade_t;

static void ztd_gain_apply_native(const float *in, float *out, float factor, uint32_t frames) ZTD_NONBLOCKING {
    for (uint32_t i = 0; i < frames; i++) out[i] = in[i] * factor;
}

static void ztd_gain_apply_accelerate(const float *in, float *out, float factor, uint32_t frames) ZTD_NONBLOCKING {
    vDSP_vsmul(in, 1, &factor, out, 1, frames);
}

/* One factor over one channel. While the factor ramps, frame k of the block is multiplied by
   target − increment·(remaining − 1 − k): computed from the target, not accumulated, so the ramp
   is the same whatever the block sizes and ends on the target exactly. */
static void ztd_gain_stage_run(const ztd_gain_cascade_t *cascade, const ztd_gain_stage_t *stage, const float *in,
                               float *out, uint32_t frames) ZTD_NONBLOCKING {
    uint32_t moving = stage->remaining < frames ? stage->remaining : frames;
    for (uint32_t i = 0; i < moving; i++) {
        const uint32_t left = stage->remaining - 1 - i;
        const float factor = left == 0 ? stage->target : stage->target - stage->increment * (float)left;
        out[i] = in[i] * factor;
    }
    if (frames > moving) {
        const float settled = moving > 0 ? stage->target : stage->current;
        cascade->apply(in + moving, out + moving, settled, frames - moving);
    }
}

static uint32_t ztd_gain_cascade_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                         uint32_t frames) ZTD_NONBLOCKING {
    ztd_gain_cascade_t *cascade = state;
    for (uint32_t channel = 0; channel < channels; channel++) {
        const float *source = in[channel];
        for (uint32_t index = 0; index < cascade->count; index++) {
            const ztd_gain_stage_t *stage = &cascade->stages[index];
            /* A factor that rests at 1 changes no sample, so it is not applied: a gain that a
               command brought to 0 dB costs what a kernel that was never made costs (F4). */
            if (stage->remaining == 0 && stage->current == 1.0f) continue;
            ztd_gain_stage_run(cascade, stage, source, out[channel], frames);
            source = out[channel];      /* later factors work in place on the output */
        }
        if (source == in[channel]) memcpy(out[channel], in[channel], (size_t)frames * sizeof(float));
    }
    /* Advance every ramp once per block, after all channels used the same values. */
    for (uint32_t index = 0; index < cascade->count; index++) {
        ztd_gain_stage_t *stage = &cascade->stages[index];
        if (stage->remaining == 0) continue;
        const uint32_t moved = stage->remaining < frames ? stage->remaining : frames;
        stage->remaining -= moved;
        stage->current = stage->remaining == 0 ? stage->target : stage->target - stage->increment * (float)stage->remaining;
    }
    return frames;
}

static void ztd_gain_cascade_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_gain_cascade_t *cascade = state;
    if (command->kind != ZTD_COMMAND_SET_VALUES || !command->values) return;
    const float *values = command->values;
    const uint32_t count = command->count < cascade->count ? command->count : cascade->count;
    for (uint32_t index = 0; index < count; index++) {
        ztd_gain_stage_t *stage = &cascade->stages[index];
        stage->target = values[index];
        if (cascade->ramp_frames == 0 || stage->target == stage->current) {
            stage->current = stage->target;
            stage->increment = 0.0f;
            stage->remaining = 0;
        } else {
            stage->increment = (stage->target - stage->current) / (float)cascade->ramp_frames;
            stage->remaining = cascade->ramp_frames;
        }
    }
}

static void ztd_gain_cascade_reset(void *state) ZTD_NONBLOCKING {
    ztd_gain_cascade_t *cascade = state;
    /* A reset is a cold start, not a return to old values: the factors stay where the last
       command put them, and a ramp in flight lands. */
    for (uint32_t index = 0; index < cascade->count; index++) {
        ztd_gain_stage_t *stage = &cascade->stages[index];
        stage->current = stage->target;
        stage->increment = 0.0f;
        stage->remaining = 0;
    }
}

static void ztd_gain_cascade_destroy(void *state) {
    ztd_gain_cascade_t *cascade = state;
    if (!cascade) return;
    free(cascade->stages);
    free(cascade);
}

ztd_kernel_t ztd_gain_cascade_create(uint32_t channels, const float *factors, uint32_t count,
                                     uint32_t ramp_frames, ztd_implementation_t implementation) {
    ztd_kernel_t kernel = ztd_kernel_null();
    if (channels == 0 || count > ZTD_LIMIT || (count > 0 && !factors)) return kernel;
    ztd_gain_cascade_t *cascade = (ztd_gain_cascade_t *)ztd_allocate(1, sizeof(ztd_gain_cascade_t));
    if (!cascade) return kernel;
    cascade->count = count;
    cascade->ramp_frames = ramp_frames;
    cascade->stages = (ztd_gain_stage_t *)ztd_allocate(count > 0 ? count : 1, sizeof(ztd_gain_stage_t));
    if (!cascade->stages) {
        ztd_gain_cascade_destroy(cascade);
        return kernel;
    }
    for (uint32_t index = 0; index < count; index++) {
        cascade->stages[index].current = factors[index];
        cascade->stages[index].target = factors[index];
    }
    cascade->apply = implementation == ZTD_IMPLEMENTATION_ACCELERATE ? ztd_gain_apply_accelerate : ztd_gain_apply_native;
    kernel.process = ztd_gain_cascade_process;
    kernel.command = ztd_gain_cascade_command;
    kernel.reset = ztd_gain_cascade_reset;
    kernel.destroy = ztd_gain_cascade_destroy;
    kernel.state = cascade;
    kernel.latency_frames = 0;
    kernel.settling_frames = 0;
    return kernel;
}

/* --- A plan as one kernel ------------------------------------------------------------------- */

static uint32_t ztd_nested_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                   uint32_t frames) ZTD_NONBLOCKING {
    return ztd_plan_run((ztd_plan_t *)state, in, out, channels, frames);
}

static void ztd_nested_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    /* `target` named this kernel in the outer plan; `flags` names the kernel inside. */
    ztd_command_t inner = *command;
    inner.target = command->flags;
    inner.flags = 0;
    ztd_plan_command((ztd_plan_t *)state, &inner);
}

static void ztd_nested_reset(void *state) ZTD_NONBLOCKING {
    ztd_plan_reset((ztd_plan_t *)state);
}

static void ztd_nested_destroy(void *state) {
    ztd_plan_destroy((ztd_plan_t *)state);
}

ztd_kernel_t ztd_plan_as_kernel(ztd_plan_t *plan) {
    ztd_kernel_t kernel = ztd_kernel_null();
    if (!plan) return kernel;
    uint32_t settling = 0;
    for (uint32_t index = 0; index < ztd_plan_count(plan); index++) settling += ztd_plan_kernel(plan, index).settling_frames;
    kernel.process = ztd_nested_process;
    kernel.command = ztd_nested_command;
    kernel.reset = ztd_nested_reset;
    kernel.destroy = ztd_nested_destroy;
    kernel.state = plan;
    kernel.latency_frames = ztd_plan_latency(plan);
    kernel.settling_frames = settling;
    return kernel;
}

/* --- Non-finite guard ------------------------------------------------------------------------ */

uint32_t ztd_copy_finite(const float *in, float *out, uint32_t frames) ZTD_NONBLOCKING {
    /* A float is finite exactly when its exponent bits are not all ones. The test is on the bit
       pattern, so it holds whatever the floating-point flags of the build are, and the loop has
       no branch for the compiler to trip over when it vectorises. */
    uint32_t replaced = 0;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t bits;
        __builtin_memcpy(&bits, &in[i], sizeof(bits));
        const uint32_t finite = (bits & 0x7F800000u) != 0x7F800000u;
        bits &= 0u - finite;
        replaced += 1u - finite;
        __builtin_memcpy(&out[i], &bits, sizeof(bits));
    }
    return replaced;
}

/* --- Parking -------------------------------------------------------------------------------- */

struct ztd_parker {
    pthread_mutex_t mutex;
    pthread_cond_t condition;
    bool permit;
    _Atomic(uint64_t) parks;
};

ztd_parker_t *ztd_parker_create(void) {
    ztd_parker_t *parker = (ztd_parker_t *)ztd_allocate(1, sizeof(ztd_parker_t));
    if (!parker) return NULL;
    pthread_mutex_init(&parker->mutex, NULL);
    pthread_cond_init(&parker->condition, NULL);
    atomic_init(&parker->parks, 0);
    return parker;
}

void ztd_parker_destroy(ztd_parker_t *parker) {
    if (!parker) return;
    pthread_cond_destroy(&parker->condition);
    pthread_mutex_destroy(&parker->mutex);
    free(parker);
}

void ztd_parker_park(ztd_parker_t *parker) {
    pthread_mutex_lock(&parker->mutex);
    if (!parker->permit) {
        atomic_fetch_add_explicit(&parker->parks, 1, memory_order_relaxed);
        while (!parker->permit) pthread_cond_wait(&parker->condition, &parker->mutex);
    }
    parker->permit = false;
    pthread_mutex_unlock(&parker->mutex);
}

void ztd_parker_unpark(ztd_parker_t *parker) {
    pthread_mutex_lock(&parker->mutex);
    parker->permit = true;
    pthread_cond_signal(&parker->condition);
    pthread_mutex_unlock(&parker->mutex);
}

uint64_t ztd_parker_park_count(const ztd_parker_t *parker) {
    return atomic_load_explicit(&((ztd_parker_t *)parker)->parks, memory_order_relaxed);
}
