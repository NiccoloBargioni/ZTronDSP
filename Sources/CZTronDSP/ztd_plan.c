#include "ztd_plan.h"

#include <stdlib.h>

#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* An activation switch: the run-time half of `isActive:` when it is bound (§5.9). */
typedef struct ztd_switch {
    ztd_switch_state_t state;
    ztd_crossfade_t fade;
    uint32_t fade_frames;
    uint32_t preroll_frames;    /* how long the kernel runs unheard before it is faded in (ACT-7) */
    uint32_t preroll_position;
    uint32_t latency;           /* frames of the delay line on the unprocessed path (ACT-8); 0: none */
    uint32_t delay_position;    /* where the oldest sample of each delay line sits */
    float **delay;              /* per channel: the last `latency` input samples, as a ring */
    float **dry;                /* per channel: the unprocessed signal of the current block */
} ztd_switch_t;

typedef struct ztd_entry {
    ztd_kernel_t kernel;
    ztd_switch_t *sw;           /* NULL for a stage with a constant activation: no cost at all */
    bool owned;
} ztd_entry_t;

struct ztd_plan {
    uint32_t count;
    uint32_t capacity;
    uint32_t channels;
    uint32_t maximum_frames;
    ztd_entry_t *entries;
    float **scratch[2];         /* two channel tables, used alternately between kernels */
};

/* --- Control context ------------------------------------------------------------------------ */

/* A table of channel pointers into one allocation. The slot before the table holds the
   allocation itself, because the channels start at the buffer's own offset within a page
   (ztd_buffer_color), not at its base. NULL when memory cannot be had, and for a table of more
   samples than a plan may hold (ZTD_PLAN_SAMPLE_LIMIT), which is refused before anything is
   asked for. */
static float **ztd_channel_table(uint32_t channels, uint32_t frames) {
    const size_t count = channels > 0 ? channels : 1;
    const size_t stride = ((size_t)(frames > 0 ? frames : 1) + 15u) & ~(size_t)15u;
    if (stride > ZTD_PLAN_SAMPLE_LIMIT / count) return NULL;
    float **slots = (float **)ztd_allocate(count + 1, sizeof(float *));
    if (!slots) return NULL;
    /* Zero-filled, which also touches every page (RT-9). */
    float *storage = (float *)ztd_allocate(stride * count * sizeof(float) + 4096u, 1);
    if (!storage) {
        free(slots);
        return NULL;
    }
    float *first = (float *)((char *)storage + ztd_buffer_color());
    slots[0] = storage;
    float **table = slots + 1;
    for (size_t channel = 0; channel < count; channel++) table[channel] = first + channel * stride;
    return table;
}

static void ztd_channel_table_free(float **table) {
    if (!table) return;
    free(table[-1]);
    free(table - 1);
}

ztd_plan_t *ztd_plan_create(uint32_t kernel_capacity, uint32_t channels, uint32_t maximum_frames) {
    if (channels == 0 || channels > ZTD_LIMIT || kernel_capacity > ZTD_LIMIT) return NULL;
    ztd_plan_t *plan = (ztd_plan_t *)ztd_allocate(1, sizeof(ztd_plan_t));
    if (!plan) return NULL;
    plan->capacity = kernel_capacity;
    plan->channels = channels;
    plan->maximum_frames = maximum_frames > 0 ? maximum_frames : 1;
    plan->entries = (ztd_entry_t *)ztd_allocate(kernel_capacity > 0 ? kernel_capacity : 1, sizeof(ztd_entry_t));
    plan->scratch[0] = ztd_channel_table(channels, plan->maximum_frames);
    plan->scratch[1] = ztd_channel_table(channels, plan->maximum_frames);
    if (!plan->entries || !plan->scratch[0] || !plan->scratch[1]) {
        ztd_plan_destroy(plan);
        return NULL;
    }
    return plan;
}

static void ztd_switch_free(ztd_switch_t *sw) {
    if (!sw) return;
    ztd_channel_table_free(sw->delay);
    ztd_channel_table_free(sw->dry);
    free(sw);
}

void ztd_plan_destroy(ztd_plan_t *plan) {
    if (!plan) return;
    if (plan->entries) {
        for (uint32_t index = 0; index < plan->count; index++) {
            ztd_entry_t *entry = &plan->entries[index];
            if (entry->owned) ztd_kernel_destroy(&entry->kernel);
            ztd_switch_free(entry->sw);
        }
    }
    free(plan->entries);
    ztd_channel_table_free(plan->scratch[0]);
    ztd_channel_table_free(plan->scratch[1]);
    free(plan);
}

uint32_t ztd_plan_append(ztd_plan_t *plan, ztd_kernel_t kernel, bool owned) {
    if (!plan || plan->count >= plan->capacity || ztd_kernel_is_null(&kernel)) return UINT32_MAX;
    ztd_entry_t *entry = &plan->entries[plan->count];
    entry->kernel = kernel;
    entry->sw = NULL;
    entry->owned = owned;
    return plan->count++;
}

bool ztd_plan_make_switchable(ztd_plan_t *plan, uint32_t index, uint32_t fade_frames, bool active) {
    if (!plan || index >= plan->count) return false;
    ztd_entry_t *entry = &plan->entries[index];
    if (entry->sw) return true;
    ztd_switch_t *sw = (ztd_switch_t *)ztd_allocate(1, sizeof(ztd_switch_t));
    if (!sw) return false;
    sw->state = active ? ZTD_SWITCH_ACTIVE : ZTD_SWITCH_BYPASSED;
    sw->fade_frames = fade_frames > 0 ? fade_frames : 1;
    /* The kernel's latency plus its settling time (ACT-7), added in a type that holds the sum:
       a kernel that states more than a switch can count is run for the largest count. */
    const uint64_t preroll = (uint64_t)entry->kernel.latency_frames + entry->kernel.settling_frames;
    sw->preroll_frames = preroll > UINT32_MAX ? UINT32_MAX : (uint32_t)preroll;
    sw->latency = entry->kernel.latency_frames;
    if (sw->latency > 0) {
        sw->delay = ztd_channel_table(plan->channels, sw->latency);
        sw->dry = ztd_channel_table(plan->channels, plan->maximum_frames);
        if (!sw->delay || !sw->dry) {
            ztd_switch_free(sw);
            return false;
        }
    }
    entry->sw = sw;
    return true;
}

bool ztd_plan_set_switch_preroll(ztd_plan_t *plan, uint32_t index, uint32_t frames) {
    if (!plan || index >= plan->count || !plan->entries[index].sw) return false;
    plan->entries[index].sw->preroll_frames = frames;
    return true;
}

bool ztd_plan_transfer(ztd_plan_t *from, uint32_t from_index, ztd_plan_t *to, uint32_t to_index) {
    if (!from || !to || from_index >= from->count || to_index >= to->count) return false;
    ztd_entry_t *source = &from->entries[from_index];
    ztd_entry_t *target = &to->entries[to_index];
    if (target->owned) ztd_kernel_destroy(&target->kernel);
    target->kernel = source->kernel;
    target->owned = source->owned;
    /* `from` keeps running the kernel until it is retired, but no longer destroys it. */
    source->owned = false;
    return true;
}

uint32_t ztd_plan_count(const ztd_plan_t *plan) ZTD_NONBLOCKING {
    return plan->count;
}

uint32_t ztd_plan_channels(const ztd_plan_t *plan) ZTD_NONBLOCKING {
    return plan->channels;
}

uint32_t ztd_plan_maximum_frames(const ztd_plan_t *plan) ZTD_NONBLOCKING {
    return plan->maximum_frames;
}

ztd_kernel_t ztd_plan_kernel(const ztd_plan_t *plan, uint32_t index) ZTD_NONBLOCKING {
    if (index < plan->count) return plan->entries[index].kernel;
    ztd_kernel_t none;
    memset(&none, 0, sizeof(none));
    return none;
}

uint32_t ztd_plan_latency(const ztd_plan_t *plan) ZTD_NONBLOCKING {
    /* Added in a type that holds the sum of any plan's kernels (at most 2^24 of them). */
    uint64_t total = 0;
    for (uint32_t index = 0; index < plan->count; index++) total += plan->entries[index].kernel.latency_frames;
    return total > UINT32_MAX ? UINT32_MAX : (uint32_t)total;
}

/* --- The unprocessed path of a switched stage ----------------------------------------------- */

/* Keeps the delay lines current without producing the delayed signal: all an active stage pays
   (one copy of the block, ACT-8). */
static void ztd_delay_feed(ztd_switch_t *sw, const float *const *in, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    const uint32_t length = sw->latency;
    if (frames >= length) {
        for (uint32_t channel = 0; channel < channels; channel++) {
            memcpy(sw->delay[channel], in[channel] + (frames - length), (size_t)length * sizeof(float));
        }
        sw->delay_position = 0;
        return;
    }
    const uint32_t position = sw->delay_position;
    const uint32_t first = frames < length - position ? frames : length - position;
    for (uint32_t channel = 0; channel < channels; channel++) {
        memcpy(sw->delay[channel] + position, in[channel], (size_t)first * sizeof(float));
        if (frames > first) memcpy(sw->delay[channel], in[channel] + first, (size_t)(frames - first) * sizeof(float));
    }
    sw->delay_position = (position + frames) % length;
}

/* Writes the input delayed by the stage's latency to `sw->dry`, and feeds the delay lines. */
static void ztd_delay_run(ztd_switch_t *sw, const float *const *in, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    const uint32_t length = sw->latency;
    const uint32_t position = sw->delay_position;
    /* The first min(frames, length) output samples are the oldest samples of the line. */
    const uint32_t from_line = frames < length ? frames : length;
    const uint32_t until_wrap = length - position;
    const uint32_t first = from_line < until_wrap ? from_line : until_wrap;
    for (uint32_t channel = 0; channel < channels; channel++) {
        float *dry = sw->dry[channel];
        memcpy(dry, sw->delay[channel] + position, (size_t)first * sizeof(float));
        if (from_line > first) memcpy(dry + first, sw->delay[channel], (size_t)(from_line - first) * sizeof(float));
        /* The rest is input that both enters and leaves the line within this block. */
        if (frames > length) memcpy(dry + length, in[channel], (size_t)(frames - length) * sizeof(float));
    }
    ztd_delay_feed(sw, in, channels, frames);
}

static void ztd_copy_block(const float *const *from, float *const *to, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    for (uint32_t channel = 0; channel < channels; channel++) {
        memcpy(to[channel], from[channel], (size_t)frames * sizeof(float));
    }
}

/* Cross-fades every channel with one fade, and advances the fade once. */
static void ztd_fade_block(ztd_switch_t *sw, const float *const *from, const float *const *to, float *const *out,
                           uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_crossfade_t fade = sw->fade;
    for (uint32_t channel = 0; channel < channels; channel++) {
        fade = sw->fade;
        ztd_crossfade_mix(&fade, from[channel], to[channel], out[channel], frames);
    }
    sw->fade = fade;
}

/* --- Analysis thread ------------------------------------------------------------------------ */

static uint32_t ztd_entry_run(ztd_entry_t *entry, const float *const *in, float *const *out, uint32_t channels,
                              uint32_t frames) ZTD_NONBLOCKING {
    ztd_switch_t *sw = entry->sw;
    /* A stage without a bound switch pays nothing; an active one pays this test (ACT-5). */
    if (!sw) return entry->kernel.process(entry->kernel.state, in, out, channels, frames);
    if (sw->state == ZTD_SWITCH_ACTIVE) {
        if (sw->latency > 0) ztd_delay_feed(sw, in, channels, frames);
        return entry->kernel.process(entry->kernel.state, in, out, channels, frames);
    }

    const float *const *dry = in;
    if (sw->latency > 0) {
        ztd_delay_run(sw, in, channels, frames);
        dry = (const float *const *)sw->dry;
    }
    const float *const *wet = (const float *const *)out;

    switch (sw->state) {
    case ZTD_SWITCH_BYPASSED:
        /* The kernel is not called at all. */
        ztd_copy_block(dry, out, channels, frames);
        break;
    case ZTD_SWITCH_FADING_OUT:
        entry->kernel.process(entry->kernel.state, in, out, channels, frames);
        ztd_fade_block(sw, wet, dry, out, channels, frames);
        if (ztd_crossfade_is_done(&sw->fade)) sw->state = ZTD_SWITCH_BYPASSED;
        break;
    case ZTD_SWITCH_PREROLLING:
        /* The kernel runs so that its state settles; what it writes is discarded. */
        entry->kernel.process(entry->kernel.state, in, out, channels, frames);
        ztd_copy_block(dry, out, channels, frames);
        /* Counted without wrapping, so a pre-roll of the largest count ends too. */
        sw->preroll_position = frames > UINT32_MAX - sw->preroll_position ? UINT32_MAX : sw->preroll_position + frames;
        if (sw->preroll_position >= sw->preroll_frames) {
            sw->state = ZTD_SWITCH_FADING_IN;
            ztd_crossfade_begin(&sw->fade, sw->fade_frames);
        }
        break;
    case ZTD_SWITCH_FADING_IN:
        entry->kernel.process(entry->kernel.state, in, out, channels, frames);
        ztd_fade_block(sw, dry, wet, out, channels, frames);
        if (ztd_crossfade_is_done(&sw->fade)) sw->state = ZTD_SWITCH_ACTIVE;
        break;
    case ZTD_SWITCH_ACTIVE:
        break;
    }
    return frames;
}

uint32_t ztd_plan_run_range(ztd_plan_t *plan, uint32_t first, uint32_t last, const float *const *in,
                            float *const *out, uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    /* Never past the buffers, whatever the caller was handed: the scratch tables and the
       caller's output hold `maximum_frames`, in `channels` channels. */
    if (frames > plan->maximum_frames) frames = plan->maximum_frames;
    if (channels > plan->channels) channels = plan->channels;
    if (last > plan->count) last = plan->count;
    if (first >= last) {
        ztd_copy_block(in, out, channels, frames);
        return frames;
    }
    const float *const *source = in;
    uint32_t count = frames;
    uint32_t side = 0;
    for (uint32_t index = first; index < last; index++) {
        float *const *target = index + 1 == last ? out : (float *const *)plan->scratch[side];
        count = ztd_entry_run(&plan->entries[index], source, target, channels, count);
        source = (const float *const *)target;
        side ^= 1u;
    }
    return count;
}

uint32_t ztd_plan_run(ztd_plan_t *plan, const float *const *in, float *const *out, uint32_t channels,
                      uint32_t frames) ZTD_NONBLOCKING {
    return ztd_plan_run_range(plan, 0, plan->count, in, out, channels, frames);
}

void ztd_plan_preroll(ztd_plan_t *plan, uint32_t first, const float *const *in, uint32_t channels,
                      uint32_t frames) ZTD_NONBLOCKING {
    if (frames > plan->maximum_frames) frames = plan->maximum_frames;
    if (channels > plan->channels) channels = plan->channels;
    const float *const *source = in;
    uint32_t count = frames;
    uint32_t side = 0;
    for (uint32_t index = first; index < plan->count; index++) {
        float *const *target = (float *const *)plan->scratch[side];
        count = ztd_entry_run(&plan->entries[index], source, target, channels, count);
        source = (const float *const *)target;
        side ^= 1u;
    }
}

static void ztd_switch_command(ztd_entry_t *entry, bool active) ZTD_NONBLOCKING {
    ztd_switch_t *sw = entry->sw;
    if (active) {
        switch (sw->state) {
        case ZTD_SWITCH_BYPASSED:
            /* A stage that was off starts cold and is pre-rolled before it is heard (ACT-7). */
            if (entry->kernel.reset) entry->kernel.reset(entry->kernel.state);
            sw->preroll_position = 0;
            if (sw->preroll_frames > 0) {
                sw->state = ZTD_SWITCH_PREROLLING;
            } else {
                sw->state = ZTD_SWITCH_FADING_IN;
                ztd_crossfade_begin(&sw->fade, sw->fade_frames);
            }
            break;
        case ZTD_SWITCH_FADING_OUT: {
            /* Still running and still warm: turn the fade around where it stands. */
            const uint32_t done = sw->fade.position;
            sw->state = ZTD_SWITCH_FADING_IN;
            ztd_crossfade_begin(&sw->fade, sw->fade_frames);
            sw->fade.position = sw->fade.total - (done < sw->fade.total ? done : sw->fade.total);
            if (ztd_crossfade_is_done(&sw->fade)) sw->state = ZTD_SWITCH_ACTIVE;
            break;
        }
        case ZTD_SWITCH_ACTIVE:
        case ZTD_SWITCH_PREROLLING:
        case ZTD_SWITCH_FADING_IN:
            break;
        }
    } else {
        switch (sw->state) {
        case ZTD_SWITCH_ACTIVE:
            sw->state = ZTD_SWITCH_FADING_OUT;
            ztd_crossfade_begin(&sw->fade, sw->fade_frames);
            break;
        case ZTD_SWITCH_FADING_IN: {
            const uint32_t done = sw->fade.position;
            sw->state = ZTD_SWITCH_FADING_OUT;
            ztd_crossfade_begin(&sw->fade, sw->fade_frames);
            sw->fade.position = sw->fade.total - (done < sw->fade.total ? done : sw->fade.total);
            if (ztd_crossfade_is_done(&sw->fade)) sw->state = ZTD_SWITCH_BYPASSED;
            break;
        }
        case ZTD_SWITCH_PREROLLING:
            /* Nothing of the stage was audible yet. */
            sw->state = ZTD_SWITCH_BYPASSED;
            break;
        case ZTD_SWITCH_BYPASSED:
        case ZTD_SWITCH_FADING_OUT:
            break;
        }
    }
}

void ztd_plan_command(ztd_plan_t *plan, const ztd_command_t *command) ZTD_NONBLOCKING {
    if (command->target >= plan->count) return;
    ztd_entry_t *entry = &plan->entries[command->target];
    if (command->kind == ZTD_COMMAND_SET_ACTIVE) {
        if (entry->sw) ztd_switch_command(entry, command->scalar[0] != 0.0);
        return;
    }
    if (entry->kernel.command) entry->kernel.command(entry->kernel.state, command);
}

void ztd_plan_reset(ztd_plan_t *plan) ZTD_NONBLOCKING {
    for (uint32_t index = 0; index < plan->count; index++) {
        ztd_entry_t *entry = &plan->entries[index];
        if (entry->kernel.reset) entry->kernel.reset(entry->kernel.state);
        ztd_switch_t *sw = entry->sw;
        if (!sw) continue;
        if (sw->state == ZTD_SWITCH_FADING_OUT) sw->state = ZTD_SWITCH_BYPASSED;
        if (sw->state == ZTD_SWITCH_PREROLLING || sw->state == ZTD_SWITCH_FADING_IN) sw->state = ZTD_SWITCH_ACTIVE;
        sw->preroll_position = 0;
        sw->delay_position = 0;
        for (uint32_t channel = 0; channel < plan->channels && sw->latency > 0; channel++) {
            memset(sw->delay[channel], 0, (size_t)sw->latency * sizeof(float));
        }
    }
}

ztd_switch_state_t ztd_plan_switch_state(const ztd_plan_t *plan, uint32_t index) ZTD_NONBLOCKING {
    if (index >= plan->count || !plan->entries[index].sw) return ZTD_SWITCH_ACTIVE;
    return plan->entries[index].sw->state;
}
