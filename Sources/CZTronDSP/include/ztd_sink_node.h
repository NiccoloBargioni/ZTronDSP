#ifndef ZTD_SINK_NODE_H
#define ZTD_SINK_NODE_H

#include "ztd_base.h"
#include "ztd_ring.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   The sink-node factory (WP-703): how frames get from the audio I/O thread into a ring.

   A hardware source runs an AVAudioEngine whose only connection is input node → AVAudioSinkNode
   (§4.6). The sink node's receiver block runs on the Core Audio I/O thread, so it is written
   here, in the one target that may run there (RT-1): it is non-blocking, it is compiled with
   function-effect warnings as errors, and it does one thing, which is to copy the frames it is
   given into a ring. It makes no system call and sends no Objective-C message (§4.3).

   Two halves:

     - the tap (plain C): the receiving function and the slot that names the ring it writes;
     - the factory (Objective-C): the AVAudioSinkNode whose block calls that function, made with
       the real-time-safe initialiser where the system has one (iOS 27, E-02) and with the classic
       one before.

   This header imports neither AVFAudio nor CoreAudioTypes: the two system types it mentions are
   named as incomplete types, so a file that only wants the kernels is not handed a framework. A
   file that calls these functions imports AVFAudio itself.
   --------------------------------------------------------------------------------------------- */

struct AudioBufferList; /* <CoreAudioTypes/CoreAudioBaseTypes.h> */
struct AudioTimeStamp;

/* What a sink node's block writes to: a slot that holds the ring in use, and counters.

   Threading: `ztd_sink_tap_receive` belongs to one thread at a time, the I/O thread. Everything
   else belongs to the control context, except the counters, which any thread may read. */
typedef struct ztd_sink_tap ztd_sink_tap_t;

/* The most channels a tap can take: a ring of more cannot be connected. */
#define ZTD_SINK_TAP_MAX_CHANNELS 256u

/* Creates a tap with no ring, held once. NULL when memory cannot be had. Control context. */
ztd_sink_tap_t *ztd_sink_tap_create(void);

/* A tap is shared by the source that connects rings to it and by the node whose block writes to
   it, so it is counted: each holder releases what it retained, and the last release frees the
   tap. NULL is allowed. Control context; the last release only once no receive can run. */
void ztd_sink_tap_retain(ztd_sink_tap_t *tap);
void ztd_sink_tap_release(ztd_sink_tap_t *tap);

/* Makes `ring` the ring the tap writes, or, with NULL, none: frames that arrive then are
   discarded and counted. Returns once no receive can still be writing the previous ring, so the
   caller may let go of that ring at once. The I/O thread is never made to wait for this call:
   the call waits for the I/O thread, for as long as one receive lasts.
   False, with the tap unchanged, for a ring of more than ZTD_SINK_TAP_MAX_CHANNELS channels.
   Control context: it may sleep. */
bool ztd_sink_tap_set_ring(ztd_sink_tap_t *tap, ztd_ring_t *ring);

/* The receiving function: copies `frames` frames of Float32 from `buffers` into the tap's ring
   and returns 0 (noErr). This is the whole of what runs on the I/O thread.

   `buffers` is taken as it comes from an AVAudioSinkNode or from a node tap: one buffer per
   channel (the engine's standard, non-interleaved layout), or one buffer that holds every
   channel interleaved. A layout that is neither, a channel count that is not the ring's, a
   buffer without data, or no ring at all discards the frames and counts them: nothing is ever
   written past what a buffer holds or into a ring of another shape. When a buffer holds fewer
   frames than `frames` says, the frames it holds are taken. A full ring drops the newest frames
   and counts them itself (RT-8). */
int32_t ztd_sink_tap_receive(ztd_sink_tap_t *tap, const struct AudioBufferList *buffers, uint32_t frames) ZTD_NONBLOCKING;

/* Frames written into a ring so far. */
uint64_t ztd_sink_tap_written_frames(const ztd_sink_tap_t *tap) ZTD_NONBLOCKING;

/* Frames that arrived while the tap had no ring, or in a layout its ring does not have. */
uint64_t ztd_sink_tap_discarded_frames(const ztd_sink_tap_t *tap) ZTD_NONBLOCKING;

#ifdef __OBJC__

@class AVAudioSinkNode;

/* The shape of a sink node's receiver block (AVAudioSinkNodeReceiverBlock, spelled without the
   framework's names). */
typedef int32_t (^ztd_sink_receiver_t)(const struct AudioTimeStamp *timestamp, uint32_t frames,
                                       const struct AudioBufferList *buffers);

/* True where AVAudioSinkNode has the real-time-safe initialiser (iOS 27 and later). */
bool ztd_sink_node_has_realtime_safe_initialiser(void);

/* The block the factory hands a sink node: it calls `ztd_sink_tap_receive` with `tap` and does
   nothing else. With `realtime_safe` the block is the one declared non-blocking, as
   `initWithRealtimeSafeReceiverBlock:` asks; without, it is the block of the classic
   initialiser. Both are the same code; the difference is what the compiler was asked to prove.
   The block does not keep the tap alive: its caller does. A test drives it with a synthetic
   buffer list (E-14: a sink node does not run in manual rendering mode). NULL without a tap. */
ztd_sink_receiver_t ztd_sink_node_receiver(ztd_sink_tap_t *tap, bool realtime_safe);

/* A sink node whose block writes to `tap`. The node keeps the tap alive for as long as it
   lives. With `realtime_safe` the node is made with `initWithRealtimeSafeReceiverBlock:` where
   the system has it and with `initWithReceiverBlock:` where it does not; without, always with
   the classic initialiser. nil without a tap. Control context. */
AVAudioSinkNode *ztd_sink_node_create(ztd_sink_tap_t *tap, bool realtime_safe);

#endif /* __OBJC__ */

#ifdef __cplusplus
}
#endif

#endif /* ZTD_SINK_NODE_H */
