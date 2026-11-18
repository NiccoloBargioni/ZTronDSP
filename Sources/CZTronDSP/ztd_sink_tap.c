#include "ztd_sink_node.h"

#include "ztd_internal.h"

#include <CoreAudioTypes/CoreAudioBaseTypes.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <time.h>

/* The tap behind a sink node (WP-703): the one function of the package that runs on the audio
   I/O thread, and the slot through which the control context tells it which ring to write.

   How the ring changes hands without a lock. The receiving thread brackets every call with two
   increments of `sequence`, so the counter is odd exactly while a receive is in progress, and
   loads the ring pointer inside that bracket. The control context stores the new pointer first
   and reads the counter second. All four accesses are sequentially consistent, so they have one
   order, and two cases remain:

     - the counter read was even: no receive was in progress, and every receive that begins
       later loads the pointer after it was stored, so it sees the new ring;
     - the counter read was odd: one receive is in progress and may hold the old ring. The
       control context waits until the counter has moved; that receive is then over, and every
       later one began after the store.

   Either way, when `ztd_sink_tap_set_ring` returns, nobody writes the old ring any more. The
   receiving thread never waits and never retries: the wait is the control context's alone. */

struct ztd_sink_tap {
    _Atomic(ztd_ring_t *) ring;
    _Atomic(uint64_t) sequence; /* odd while a receive is in progress */
    _Atomic(uint64_t) written;
    _Atomic(uint64_t) discarded;
    _Atomic(uint32_t) holders;
    /* The receiving thread's own: one pointer per channel of the buffer list in hand. */
    const float *channels[ZTD_SINK_TAP_MAX_CHANNELS];
};

ztd_sink_tap_t *ztd_sink_tap_create(void) {
    ztd_sink_tap_t *tap = (ztd_sink_tap_t *)ztd_allocate(1, sizeof(ztd_sink_tap_t));
    if (!tap) return NULL;
    atomic_init(&tap->ring, NULL);
    atomic_init(&tap->sequence, 0);
    atomic_init(&tap->written, 0);
    atomic_init(&tap->discarded, 0);
    atomic_init(&tap->holders, 1);
    return tap;
}

void ztd_sink_tap_retain(ztd_sink_tap_t *tap) {
    if (tap) atomic_fetch_add(&tap->holders, 1);
}

void ztd_sink_tap_release(ztd_sink_tap_t *tap) {
    if (tap && atomic_fetch_sub(&tap->holders, 1) == 1) free(tap);
}

bool ztd_sink_tap_set_ring(ztd_sink_tap_t *tap, ztd_ring_t *ring) {
    if (!tap) return false;
    if (ring && ztd_ring_channels(ring) > ZTD_SINK_TAP_MAX_CHANNELS) return false;
    atomic_store(&tap->ring, ring);
    const uint64_t seen = atomic_load(&tap->sequence);
    if ((seen & 1) != 0) {
        /* A receive is in progress: it lasts as long as one copy. */
        long pause = 20 * 1000; /* nanoseconds, doubling up to one millisecond */
        while (atomic_load(&tap->sequence) == seen) {
            struct timespec interval = {0, pause};
            nanosleep(&interval, NULL);
            if (pause < 1000 * 1000) pause *= 2;
        }
    }
    return true;
}

/* Frames of `channels` interleaved channels that a buffer holds. */
static inline uint32_t ztd_sink_frames_held(const AudioBuffer *buffer, uint32_t channels) ZTD_NONBLOCKING {
    return buffer->mDataByteSize / ((uint32_t)sizeof(float) * channels);
}

int32_t ztd_sink_tap_receive(ztd_sink_tap_t *tap, const struct AudioBufferList *buffers, uint32_t frames) ZTD_NONBLOCKING {
    if (!tap || !buffers || frames == 0) return 0;
    atomic_fetch_add(&tap->sequence, 1);
    ztd_ring_t *ring = atomic_load(&tap->ring);
    const uint32_t channels = ztd_ring_channels(ring); /* 0 without a ring */
    const uint32_t count = buffers->mNumberBuffers;
    bool taken = false;
    uint32_t written = 0;

    if (channels != 0 && count == channels) {
        /* One buffer per channel: the engine's standard layout. (One channel is this case too.) */
        uint32_t usable = frames;
        bool planar = true;
        for (uint32_t channel = 0; channel < channels; channel++) {
            const AudioBuffer *buffer = &buffers->mBuffers[channel];
            if (buffer->mNumberChannels != 1 || !buffer->mData) {
                planar = false;
                break;
            }
            usable = ztd_min_u32(usable, ztd_sink_frames_held(buffer, 1));
            tap->channels[channel] = (const float *)buffer->mData;
        }
        if (planar) {
            written = ztd_ring_write(ring, tap->channels, usable);
            taken = true;
        }
    } else if (channels != 0 && count == 1) {
        /* One buffer that holds every channel, interleaved. */
        const AudioBuffer *buffer = &buffers->mBuffers[0];
        if (buffer->mNumberChannels == channels && buffer->mData) {
            const uint32_t usable = ztd_min_u32(frames, ztd_sink_frames_held(buffer, channels));
            written = ztd_ring_write_interleaved(ring, (const float *)buffer->mData, usable);
            taken = true;
        }
    }

    if (taken) {
        atomic_fetch_add_explicit(&tap->written, written, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&tap->discarded, frames, memory_order_relaxed);
    }
    atomic_fetch_add(&tap->sequence, 1);
    return 0;
}

uint64_t ztd_sink_tap_written_frames(const ztd_sink_tap_t *tap) ZTD_NONBLOCKING {
    return tap ? atomic_load_explicit(&tap->written, memory_order_relaxed) : 0;
}

uint64_t ztd_sink_tap_discarded_frames(const ztd_sink_tap_t *tap) ZTD_NONBLOCKING {
    return tap ? atomic_load_explicit(&tap->discarded, memory_order_relaxed) : 0;
}
