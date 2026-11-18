#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* The gain kernel (WP-207): out = in * g per channel, with a linear ramp to a changed gain.

   The gain of every frame is a closed form of the frame's place in the ramp, not a running sum:
   with `left` frames still to come after it,

       g = target - increment * left        (and exactly `target` when left == 0)

   so a ramp lands on its target exactly, is the same for any sequence of block sizes, and both
   implementations compute the same floats. vDSP_vrampmul is not used for the ramp: its output
   does not match the scalar loop its header documents bit for bit (measured on the host of §3:
   1 885 of 2 000 random ramps differ; it steps the ramp in vector lanes, which rounds
   differently), and it carries the ramp's value from call to call, so its rounding would also
   depend on the block sizes. The ramp is rendered here and multiplied in with vDSP_vmul. */

/* Each product below is rounded on its own: a fused multiply-add would differ from the scalar
   reference in the last bit. */
#pragma STDC FP_CONTRACT OFF

/* Frames of the ramp rendered at a time. */
#define ZTD_GAIN_CHUNK 512u

typedef void (*ztd_gain_scale_fn)(const float *in, float gain, float *out, uint32_t frames) ZTD_NONBLOCKING;
typedef void (*ztd_gain_multiply_fn)(const float *in, const float *gains, float *out, uint32_t frames) ZTD_NONBLOCKING;

typedef struct ztd_gain_channel {
    float current;      /* the gain of the frame processed last */
    float target;
    float increment;    /* per frame, while moving */
    uint32_t remaining; /* frames of the ramp still to come; 0 at rest */
} ztd_gain_channel_t;

typedef struct ztd_gain {
    uint32_t channels;
    uint32_t ramp_frames;
    ztd_gain_scale_fn scale;       /* bound when the kernel is created (SEL-3) */
    ztd_gain_multiply_fn multiply; /* likewise */
    ztd_gain_channel_t *channel;
    float *curve; /* ZTD_GAIN_CHUNK gains */
} ztd_gain_t;

/* The native loops, four lanes at a time and sixteen frames per turn (see ztd_float4 for why
   they are written out). Each lane is one IEEE multiplication, as in the scalar loop that
   finishes the block: the floats are the same. `in` and `out` never alias (the kernel ABI), and
   the rendered ramp is the kernel's own. */
static void ztd_gain_scale_native(const float *restrict in, float gain, float *restrict out,
                                  uint32_t frames) ZTD_NONBLOCKING {
    const ztd_float4 gains = {gain, gain, gain, gain};
    uint32_t frame = 0;
    for (; frame + 16 <= frames; frame += 16) {
        ztd_store4(out + frame, ztd_load4(in + frame) * gains);
        ztd_store4(out + frame + 4, ztd_load4(in + frame + 4) * gains);
        ztd_store4(out + frame + 8, ztd_load4(in + frame + 8) * gains);
        ztd_store4(out + frame + 12, ztd_load4(in + frame + 12) * gains);
    }
    for (; frame + 4 <= frames; frame += 4) ztd_store4(out + frame, ztd_load4(in + frame) * gains);
    for (; frame < frames; frame++) out[frame] = in[frame] * gain;
}

static void ztd_gain_multiply_native(const float *restrict in, const float *restrict gains, float *restrict out,
                                     uint32_t frames) ZTD_NONBLOCKING {
    uint32_t frame = 0;
    for (; frame + 4 <= frames; frame += 4) ztd_store4(out + frame, ztd_load4(in + frame) * ztd_load4(gains + frame));
    for (; frame < frames; frame++) out[frame] = in[frame] * gains[frame];
}

static void ztd_gain_scale_accelerate(const float *in, float gain, float *out, uint32_t frames) ZTD_NONBLOCKING {
    vDSP_vsmul(in, 1, &gain, out, 1, frames);
}

static void ztd_gain_multiply_accelerate(const float *in, const float *gains, float *out,
                                         uint32_t frames) ZTD_NONBLOCKING {
    vDSP_vmul(in, 1, gains, 1, out, 1, frames);
}

static uint32_t ztd_gain_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                 uint32_t frames) ZTD_NONBLOCKING {
    ztd_gain_t *gain = (ztd_gain_t *)state;
    const uint32_t count = ztd_min_u32(channels, gain->channels);
    for (uint32_t index = 0; index < count; index++) {
        ztd_gain_channel_t *channel = &gain->channel[index];
        const float *source = in[index];
        float *destination = out[index];
        uint32_t done = 0;
        while (channel->remaining > 0 && done < frames) {
            const uint32_t moving = ztd_min_u32(ztd_min_u32(frames - done, channel->remaining), ZTD_GAIN_CHUNK);
            for (uint32_t frame = 0; frame < moving; frame++) {
                const uint32_t left = channel->remaining - 1 - frame;
                gain->curve[frame] = left == 0 ? channel->target : channel->target - channel->increment * (float)left;
            }
            gain->multiply(source + done, gain->curve, destination + done, moving);
            channel->current = gain->curve[moving - 1];
            channel->remaining -= moving;
            done += moving;
        }
        if (done < frames) gain->scale(source + done, channel->current, destination + done, frames - done);
    }
    return frames;
}

/* Starts a move from the gain in force to `target`, over the kernel's ramp length. */
static void ztd_gain_move(const ztd_gain_t *gain, ztd_gain_channel_t *channel, float target) ZTD_NONBLOCKING {
    channel->target = target;
    if (gain->ramp_frames == 0 || target == channel->current) {
        channel->current = target;
        channel->increment = 0.0f;
        channel->remaining = 0;
    } else {
        channel->increment = (target - channel->current) / (float)gain->ramp_frames;
        channel->remaining = gain->ramp_frames;
    }
}

static void ztd_gain_command(void *state, const ztd_command_t *command) ZTD_NONBLOCKING {
    ztd_gain_t *gain = (ztd_gain_t *)state;
    if (!command || command->kind != ZTD_COMMAND_SET_VALUES) return;
    if (command->count == gain->channels && command->values) {
        const float *targets = (const float *)command->values;
        for (uint32_t index = 0; index < gain->channels; index++) ztd_gain_move(gain, &gain->channel[index], targets[index]);
    } else if (command->count == 1) {
        /* One gain for every channel, carried in the message itself. */
        const float target = (float)command->scalar[0];
        for (uint32_t index = 0; index < gain->channels; index++) ztd_gain_move(gain, &gain->channel[index], target);
    }
}

/* A cold start keeps the gain last asked for and forgets the move towards it. */
static void ztd_gain_reset(void *state) ZTD_NONBLOCKING {
    ztd_gain_t *gain = (ztd_gain_t *)state;
    for (uint32_t index = 0; index < gain->channels; index++) {
        ztd_gain_channel_t *channel = &gain->channel[index];
        channel->current = channel->target;
        channel->increment = 0.0f;
        channel->remaining = 0;
    }
}

static void ztd_gain_destroy(void *state) {
    ztd_gain_t *gain = (ztd_gain_t *)state;
    if (!gain) return;
    free(gain->channel);
    free(gain->curve);
    free(gain);
}

ztd_kernel_t ztd_gain_create(uint32_t channels, const float *gains, uint32_t ramp_frames,
                             ztd_implementation_t implementation) {
    if (channels == 0 || channels > ZTD_LIMIT) return ztd_kernel_null();
    if (implementation != ZTD_IMPLEMENTATION_NATIVE && implementation != ZTD_IMPLEMENTATION_ACCELERATE) {
        return ztd_kernel_null();
    }
    if (gains) {
        for (uint32_t index = 0; index < channels; index++) {
            if (!isfinite(gains[index])) return ztd_kernel_null();
        }
    }
    ztd_gain_t *gain = (ztd_gain_t *)ztd_allocate(1, sizeof(ztd_gain_t));
    if (!gain) return ztd_kernel_null();
    gain->channels = channels;
    gain->ramp_frames = ramp_frames;
    gain->channel = (ztd_gain_channel_t *)ztd_allocate(channels, sizeof(ztd_gain_channel_t));
    gain->curve = (float *)ztd_allocate(ZTD_GAIN_CHUNK, sizeof(float));
    if (!gain->channel || !gain->curve) {
        ztd_gain_destroy(gain);
        return ztd_kernel_null();
    }
    if (implementation == ZTD_IMPLEMENTATION_ACCELERATE) {
        gain->scale = ztd_gain_scale_accelerate;
        gain->multiply = ztd_gain_multiply_accelerate;
    } else {
        gain->scale = ztd_gain_scale_native;
        gain->multiply = ztd_gain_multiply_native;
    }
    for (uint32_t index = 0; index < channels; index++) {
        const float value = gains ? gains[index] : 1.0f;
        gain->channel[index].current = value;
        gain->channel[index].target = value;
    }
    ztd_kernel_t kernel = {
        .process = ztd_gain_process,
        .command = ztd_gain_command,
        .reset = ztd_gain_reset,
        .destroy = ztd_gain_destroy,
        .state = gain,
        .latency_frames = 0,
        .settling_frames = 0,
    };
    return kernel;
}
