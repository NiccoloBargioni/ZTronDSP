#include "ztd_ring.h"

#include "ztd_internal.h"

#include <mach/mach.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* The frames are moved with the compiler's own memcpy, not with the checked variant <string.h>
   may put in its place: the Thread Sanitizer instruments the first and cannot see into the
   second, and a race on the frames themselves is exactly what its run is there to report. */
#define ztd_ring_copy(destination, source, bytes) __builtin_memcpy((destination), (source), (bytes))

/* The SPSC ring (WP-202), its mirrored storage (WP-203) and its lossless mode (WP-222).

   Positions are 64-bit counts of frames ever written and ever consumed: they never wrap in the
   life of a process (2^64 frames is millions of years of audio), so "how many are in the ring"
   is one subtraction and an index is one mask. The writer owns `written`, the reader owns
   `consumed`; each publishes its own counter with a release store after the copy and reads the
   other's with an acquire load, which is all the synchronisation a single producer and a single
   consumer need. The two counters sit on separate cache lines so the threads do not contend. */

#define ZTD_RING_CACHE_LINE 128
#define ZTD_RING_MAX_FRAMES ((uint32_t)1 << 30)

struct ztd_ring {
    uint32_t channels;
    uint32_t capacity;   /* frames; a power of two */
    uint32_t mask;       /* capacity - 1 */
    bool mirrored;
    float **data;        /* one base pointer per channel */
    void *region;        /* the mapping (mirrored) or the block (plain) behind `data` */
    size_t region_bytes;

    _Alignas(ZTD_RING_CACHE_LINE) _Atomic(uint64_t) written; /* the writer's */
    _Atomic(uint64_t) dropped;                               /* the writer's */
    _Alignas(ZTD_RING_CACHE_LINE) _Atomic(uint64_t) consumed; /* the reader's */
    _Alignas(ZTD_RING_CACHE_LINE) _Atomic(bool) closed;
};

/* --- Storage ------------------------------------------------------------------------------- */

/* Maps every channel twice in a row: bytes [0, size) and [size, 2 * size) of a channel are the
   same physical pages, so a window that wraps is contiguous. Returns false when the system
   refuses; nothing is left mapped then. */
static bool ztd_ring_map_mirrored(ztd_ring_t *ring, size_t channel_bytes) {
    const size_t total = (size_t)ring->channels * 2 * channel_bytes;
    /* The region comes from mmap and goes back through munmap, not through Mach: it is the same
       memory, but the Thread Sanitizer follows a mapping only through these two calls. A region
       it did not see come and go keeps, to it, the accesses of whatever lived at the address
       before, and two rings that live at one address in turn then look like one ring raced
       for by the threads of both. (An annotation is no substitute: the sanitizer's
       AnnotateNewMemory does nothing.) */
    void *region = ztd_may_allocate() ? mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0) : MAP_FAILED;
    if (region == MAP_FAILED) return false;
    const vm_address_t base = (vm_address_t)region;

    bool mapped = true;
    for (uint32_t channel = 0; channel < ring->channels && mapped; channel++) {
        vm_address_t primary = base + (vm_address_t)channel * 2 * channel_bytes;
        vm_address_t mirror = primary + channel_bytes;
        vm_prot_t current = VM_PROT_NONE, maximum = VM_PROT_NONE;
        /* FIXED | OVERWRITE replaces the second half in one step: there is no moment at which
           another thread's allocation could land in the gap. */
        kern_return_t result = KERN_NO_SPACE;
        if (ztd_may_allocate()) {
            result = vm_remap(mach_task_self(), &mirror, channel_bytes, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                              mach_task_self(), primary, FALSE, &current, &maximum, VM_INHERIT_NONE);
        }
        if (result != KERN_SUCCESS || mirror != primary + channel_bytes ||
            (current & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
            mapped = false;
            break;
        }
        /* Touch both views of every page, writing, so neither the I/O thread nor the reader ever
           takes a first-touch fault (RT-9); and prove the mirror on the way: what is written
           through one view must be read through the other. */
        volatile uint8_t *first = (volatile uint8_t *)primary;
        volatile uint8_t *second = (volatile uint8_t *)mirror;
        const size_t page = (size_t)vm_page_size;
        for (size_t offset = 0; offset < channel_bytes; offset += page) {
            first[offset] = 0xA5;
            if (second[offset] != 0xA5) mapped = false;
            second[offset] = 0;
            if (first[offset] != 0) mapped = false;
        }
        ring->data[channel] = (float *)primary;
    }
    if (!mapped) {
        munmap(region, total);
        return false;
    }
    ring->region = region;
    ring->region_bytes = total;
    ring->mirrored = true;
    return true;
}

/* One block for all channels, read and written in two pieces where a window wraps. */
static bool ztd_ring_map_plain(ztd_ring_t *ring, size_t channel_bytes) {
    const size_t total = (size_t)ring->channels * channel_bytes;
    void *block = NULL;
    if (!ztd_may_allocate() || posix_memalign(&block, 64, total) != 0) return false;
    memset(block, 0, total); /* zero, and touch every page (RT-9) */
    for (uint32_t channel = 0; channel < ring->channels; channel++) {
        ring->data[channel] = (float *)((uint8_t *)block + (size_t)channel * channel_bytes);
    }
    ring->region = block;
    ring->region_bytes = total;
    ring->mirrored = false;
    return true;
}

ztd_ring_t *ztd_ring_create(uint32_t channels, uint32_t capacity_frames, ztd_ring_storage_t storage) {
    if (channels == 0 || channels > 4096 || capacity_frames == 0 || capacity_frames > ZTD_RING_MAX_FRAMES) return NULL;
    if (storage != ZTD_RING_STORAGE_AUTOMATIC && storage != ZTD_RING_STORAGE_PLAIN &&
        storage != ZTD_RING_STORAGE_MIRRORED) {
        return NULL;
    }

    uint32_t capacity = 1;
    while (capacity < capacity_frames) capacity <<= 1;
    if (storage != ZTD_RING_STORAGE_PLAIN) {
        /* A mirror maps whole pages. The page size is a power of two, so the larger of the two
           is both. An automatic ring takes this capacity whether or not the mirror is granted:
           what it holds does not depend on what the system allowed. */
        const uint32_t page_frames = (uint32_t)(vm_page_size / sizeof(float));
        if (capacity < page_frames) capacity = page_frames;
    }
    const size_t channel_bytes = (size_t)capacity * sizeof(float);

    void *memory = NULL;
    if (!ztd_may_allocate() || posix_memalign(&memory, ZTD_RING_CACHE_LINE, sizeof(ztd_ring_t)) != 0) return NULL;
    ztd_ring_t *ring = (ztd_ring_t *)memory;
    memset(ring, 0, sizeof *ring);
    ring->channels = channels;
    ring->capacity = capacity;
    ring->mask = capacity - 1;
    ring->data = ztd_may_allocate() ? (float **)calloc(channels, sizeof(float *)) : NULL;
    if (!ring->data) {
        free(ring);
        return NULL;
    }
    atomic_init(&ring->written, 0);
    atomic_init(&ring->dropped, 0);
    atomic_init(&ring->consumed, 0);
    atomic_init(&ring->closed, false);

    bool ready = false;
    if (storage != ZTD_RING_STORAGE_PLAIN) ready = ztd_ring_map_mirrored(ring, channel_bytes);
    if (!ready && storage != ZTD_RING_STORAGE_MIRRORED) ready = ztd_ring_map_plain(ring, channel_bytes);
    if (!ready) {
        free(ring->data);
        free(ring);
        return NULL;
    }
    return ring;
}

void ztd_ring_destroy(ztd_ring_t *ring) {
    if (!ring) return;
    if (ring->mirrored) {
        munmap(ring->region, ring->region_bytes);
    } else {
        free(ring->region);
    }
    free(ring->data);
    free(ring);
}

uint32_t ztd_ring_channels(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    return ring ? ring->channels : 0;
}

uint32_t ztd_ring_capacity(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    return ring ? ring->capacity : 0;
}

bool ztd_ring_is_mirrored(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    return ring ? ring->mirrored : false;
}

/* --- The writer's end ---------------------------------------------------------------------- */

static inline uint32_t ztd_ring_free_frames(const ztd_ring_t *ring, uint64_t written) ZTD_NONBLOCKING {
    uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_acquire);
    return ring->capacity - (uint32_t)(written - consumed);
}

/* Copies up to `frames` frames, starting `skip` frames into the caller's buffers, and publishes
   them. Returns how many fitted. Counts nothing. */
static uint32_t ztd_ring_put(ztd_ring_t *ring, const float *const *channels, uint32_t skip,
                             uint32_t frames) ZTD_NONBLOCKING {
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    const uint32_t space = ztd_ring_free_frames(ring, written);
    const uint32_t count = frames < space ? frames : space;
    if (count == 0) return 0;
    const uint32_t at = (uint32_t)written & ring->mask;
    /* A mirrored ring is written straight through its second view; a plain one in two pieces. */
    const uint32_t first = ring->mirrored || count <= ring->capacity - at ? count : ring->capacity - at;
    for (uint32_t channel = 0; channel < ring->channels; channel++) {
        const float *source = channels[channel] + skip;
        float *destination = ring->data[channel];
        ztd_ring_copy(destination + at, source, (size_t)first * sizeof(float));
        if (first < count) ztd_ring_copy(destination, source + first, (size_t)(count - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->written, written + count, memory_order_release);
    return count;
}

uint32_t ztd_ring_write(ztd_ring_t *ring, const float *const *channels, uint32_t frames) ZTD_NONBLOCKING {
    if (!ring || !channels) return 0;
    const uint32_t count = ztd_ring_put(ring, channels, 0, frames);
    if (count < frames) atomic_fetch_add_explicit(&ring->dropped, frames - count, memory_order_relaxed);
    return count;
}

uint32_t ztd_ring_write_interleaved(ztd_ring_t *ring, const float *samples, uint32_t frames) ZTD_NONBLOCKING {
    if (!ring || !samples) return 0;
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_relaxed);
    const uint32_t space = ztd_ring_free_frames(ring, written);
    const uint32_t count = frames < space ? frames : space;
    if (count > 0) {
        const uint32_t at = (uint32_t)written & ring->mask;
        const uint32_t first = ring->mirrored || count <= ring->capacity - at ? count : ring->capacity - at;
        const uint32_t stride = ring->channels;
        for (uint32_t channel = 0; channel < stride; channel++) {
            const float *source = samples + channel;
            float *destination = ring->data[channel];
            for (uint32_t frame = 0; frame < first; frame++) {
                destination[at + frame] = source[(size_t)frame * stride];
            }
            for (uint32_t frame = first; frame < count; frame++) {
                destination[frame - first] = source[(size_t)frame * stride];
            }
        }
        atomic_store_explicit(&ring->written, written + count, memory_order_release);
    }
    if (count < frames) atomic_fetch_add_explicit(&ring->dropped, frames - count, memory_order_relaxed);
    return count;
}

uint32_t ztd_ring_space(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    if (!ring) return 0;
    return ztd_ring_free_frames(ring, atomic_load_explicit(&ring->written, memory_order_acquire));
}

/* Deliberately NOT non-blocking: it sleeps. A non-blocking function that called it would not
   build (Scripts/check-function-effects.sh proves it). The reader's end stays free of system
   calls, so nothing signals this writer: it looks again after a short, growing pause. */
uint32_t ztd_ring_write_waiting(ztd_ring_t *ring, const float *const *channels, uint32_t frames) {
    if (!ring || !channels) return 0;
    uint32_t done = 0;
    long pause = 50 * 1000; /* nanoseconds: 50 microseconds, doubling up to one millisecond */
    while (done < frames) {
        if (atomic_load_explicit(&ring->closed, memory_order_acquire)) break;
        const uint32_t count = ztd_ring_put(ring, channels, done, frames - done);
        done += count;
        if (done == frames) break;
        if (count > 0) {
            pause = 50 * 1000; /* the reader is moving: look again soon */
            continue;
        }
        struct timespec interval = {0, pause};
        nanosleep(&interval, NULL);
        if (pause < 1000 * 1000) pause *= 2;
    }
    return done;
}

void ztd_ring_close(ztd_ring_t *ring) ZTD_NONBLOCKING {
    if (ring) atomic_store_explicit(&ring->closed, true, memory_order_release);
}

/* --- The reader's end ---------------------------------------------------------------------- */

uint32_t ztd_ring_available(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    if (!ring) return 0;
    uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_acquire);
    uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    return (uint32_t)(written - consumed);
}

uint32_t ztd_ring_read(ztd_ring_t *ring, float *const *channels, uint32_t frames) ZTD_NONBLOCKING {
    if (!ring || !channels) return 0;
    const uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    const uint32_t available = (uint32_t)(written - consumed);
    const uint32_t count = frames < available ? frames : available;
    if (count == 0) return 0;
    const uint32_t at = (uint32_t)consumed & ring->mask;
    const uint32_t first = ring->mirrored || count <= ring->capacity - at ? count : ring->capacity - at;
    for (uint32_t channel = 0; channel < ring->channels; channel++) {
        const float *source = ring->data[channel];
        float *destination = channels[channel];
        ztd_ring_copy(destination, source + at, (size_t)first * sizeof(float));
        if (first < count) ztd_ring_copy(destination + first, source, (size_t)(count - first) * sizeof(float));
    }
    atomic_store_explicit(&ring->consumed, consumed + count, memory_order_release);
    return count;
}

const float *ztd_ring_peek(const ztd_ring_t *ring, uint32_t channel, uint32_t frames) ZTD_NONBLOCKING {
    if (!ring || channel >= ring->channels) return NULL;
    const uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    if (frames > (uint32_t)(written - consumed)) return NULL;
    const uint32_t at = (uint32_t)consumed & ring->mask;
    if (!ring->mirrored && frames > ring->capacity - at) return NULL;
    return ring->data[channel] + at;
}

uint32_t ztd_ring_consume(ztd_ring_t *ring, uint32_t frames) ZTD_NONBLOCKING {
    if (!ring) return 0;
    const uint64_t consumed = atomic_load_explicit(&ring->consumed, memory_order_relaxed);
    const uint64_t written = atomic_load_explicit(&ring->written, memory_order_acquire);
    const uint32_t available = (uint32_t)(written - consumed);
    const uint32_t count = frames < available ? frames : available;
    if (count > 0) atomic_store_explicit(&ring->consumed, consumed + count, memory_order_release);
    return count;
}

/* --- Both ---------------------------------------------------------------------------------- */

uint64_t ztd_ring_overrun_frames(const ztd_ring_t *ring) ZTD_NONBLOCKING {
    return ring ? atomic_load_explicit(&ring->dropped, memory_order_relaxed) : 0;
}

void ztd_ring_reset(ztd_ring_t *ring) {
    if (!ring) return;
    atomic_store_explicit(&ring->written, 0, memory_order_release);
    atomic_store_explicit(&ring->consumed, 0, memory_order_release);
    atomic_store_explicit(&ring->dropped, 0, memory_order_release);
    atomic_store_explicit(&ring->closed, false, memory_order_release);
}
