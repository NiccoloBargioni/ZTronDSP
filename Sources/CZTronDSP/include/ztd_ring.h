#ifndef ZTD_RING_H
#define ZTD_RING_H

#include "ztd_base.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   A single-producer, single-consumer ring of planar Float32 frames (WP-202, WP-203, WP-222):
   what carries samples from an I/O thread or a reader thread to the analysis thread (RT-4).

   One thread writes, one thread reads; neither blocks the other. Capacity is a power of two.
   With mirrored storage (vm_remap, E-18) the memory is mapped twice in a row, so any window is
   contiguous and a read can be a view instead of a copy; when the mapping is refused the ring
   falls back to copying on wrap, with the same results (§13.1). The storage is touched page by
   page when the ring is created, so the I/O thread never takes a first-touch fault (RT-9).
   --------------------------------------------------------------------------------------------- */

typedef struct ztd_ring ztd_ring_t;

typedef enum ztd_ring_storage {
    ZTD_RING_STORAGE_AUTOMATIC = 0, /* mirrored when the system grants it, else plain */
    ZTD_RING_STORAGE_PLAIN = 1,     /* never mirrored: the fall-back, forced (for tests) */
    ZTD_RING_STORAGE_MIRRORED = 2,  /* mirrored or fail */
} ztd_ring_storage_t;

/* Creates a ring of `channels` channels holding at least `capacity_frames` frames (rounded up
   to a power of two, and to whole pages when mirrored). An automatic ring takes the capacity a
   mirrored one would have whether or not the mirror is granted, so what it holds does not depend
   on what the system allowed; only a ring forced to plain storage keeps the bare power of two.
   NULL when memory cannot be had, when mirroring was demanded and refused, or when there is
   nothing to create: no channels (or more than 4 096), no capacity (or more than 2^30 frames),
   an unknown kind of storage. Control context. */
ztd_ring_t *ztd_ring_create(uint32_t channels, uint32_t capacity_frames, ztd_ring_storage_t storage);
/* Frees a ring. NULL is allowed. Control context, once neither end is in use. */
void ztd_ring_destroy(ztd_ring_t *ring);

/* Every function below takes a NULL ring, or NULL buffers, as "nothing to do": it returns 0,
   false or NULL. */

uint32_t ztd_ring_channels(const ztd_ring_t *ring) ZTD_NONBLOCKING;
uint32_t ztd_ring_capacity(const ztd_ring_t *ring) ZTD_NONBLOCKING;
bool ztd_ring_is_mirrored(const ztd_ring_t *ring) ZTD_NONBLOCKING;

/* --- The writer's end ---------------------------------------------------------------------- */

/* Writes up to `frames` frames from `channels` (one pointer per channel) and returns how many
   were written. When the ring is full the frames that do not fit, the newest, are dropped and
   counted; the call never blocks and the ring never grows (RT-8). */
uint32_t ztd_ring_write(ztd_ring_t *ring, const float *const *channels, uint32_t frames) ZTD_NONBLOCKING;

/* The same from one interleaved buffer of `frames` × `channels` samples. */
uint32_t ztd_ring_write_interleaved(ztd_ring_t *ring, const float *samples, uint32_t frames) ZTD_NONBLOCKING;

/* Frames that can be written now. */
uint32_t ztd_ring_space(const ztd_ring_t *ring) ZTD_NONBLOCKING;

/* Lossless mode, for reader threads only (WP-222): waits until all `frames` are written, or
   until `ztd_ring_close` is called from another thread. Returns the frames written; nothing is
   dropped and nothing is counted as overrun. It sleeps, so it is NOT non-blocking and cannot be
   called from a non-blocking function (a build check proves it). The reader's end makes no
   system call, so nothing wakes the writer: it looks again after 50 µs, then at growing
   intervals of up to 1 ms. */
uint32_t ztd_ring_write_waiting(ztd_ring_t *ring, const float *const *channels, uint32_t frames);

/* Releases a writer waiting in ztd_ring_write_waiting, which returns what it had written, and
   makes later waiting writes return at once with nothing written. A plain ztd_ring_write is not
   affected. ztd_ring_reset reopens the ring. Any thread. */
void ztd_ring_close(ztd_ring_t *ring) ZTD_NONBLOCKING;

/* --- The reader's end ---------------------------------------------------------------------- */

/* Frames that can be read now. */
uint32_t ztd_ring_available(const ztd_ring_t *ring) ZTD_NONBLOCKING;

/* Copies up to `frames` frames into `channels` and consumes them. Returns how many. */
uint32_t ztd_ring_read(ztd_ring_t *ring, float *const *channels, uint32_t frames) ZTD_NONBLOCKING;

/* A contiguous view of the next `frames` frames of one channel, without consuming them: valid
   until the next consume on this ring. NULL when fewer frames are available, when there is no
   such channel, or when the window wraps and the ring is not mirrored (the caller then reads by
   copy). A view of 0 frames is always there. On a mirrored ring a view may be as long as the
   whole capacity, wherever it starts. */
const float *ztd_ring_peek(const ztd_ring_t *ring, uint32_t channel, uint32_t frames) ZTD_NONBLOCKING;

/* Consumes up to `frames` frames without copying them. Returns how many. */
uint32_t ztd_ring_consume(ztd_ring_t *ring, uint32_t frames) ZTD_NONBLOCKING;

/* --- Both ---------------------------------------------------------------------------------- */

/* Frames dropped by the writer since creation or the last reset. */
uint64_t ztd_ring_overrun_frames(const ztd_ring_t *ring) ZTD_NONBLOCKING;

/* Empties the ring and clears its counters. Only while neither end is in use. */
void ztd_ring_reset(ztd_ring_t *ring);

#ifdef __cplusplus
}
#endif

#endif /* ZTD_RING_H */
