#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>

#include "ztd_sink_node.h"

/* The Objective-C half of the sink-node factory (WP-703): the AVAudioSinkNode whose receiver
   block hands every buffer of the I/O thread to `ztd_sink_tap_receive`.

   What runs on the I/O thread is the body of one block: a call to a non-blocking C function with
   a captured C pointer. The block captures no Objective-C object, so entering and leaving it
   retains and releases nothing, and its body sends no message. */

/* Keeps a tap for as long as the node it is attached to lives, and gives it back when the node
   is deallocated: by then the node's audio unit is gone and no receive can run. */
@interface ZTDSinkTapHolder : NSObject
- (instancetype)initWithTap:(ztd_sink_tap_t *)tap;
@end

@implementation ZTDSinkTapHolder {
    ztd_sink_tap_t *_tap;
}

- (instancetype)initWithTap:(ztd_sink_tap_t *)tap {
    self = [super init];
    if (self) {
        ztd_sink_tap_retain(tap);
        _tap = tap;
    }
    return self;
}

- (void)dealloc {
    ztd_sink_tap_release(_tap);
}

@end

/* The receiver block with the promise the real-time-safe initialiser asks for. The attribute is
   part of the block's type, so the compiler checks the body under -Werror=function-effects
   (RT-1): a body that allocated, locked or sent a message would not build. */
typedef int32_t (^ztd_sink_receiver_nonblocking_t)(const AudioTimeStamp *timestamp, uint32_t frames,
                                                   const AudioBufferList *buffers) ZTD_NONBLOCKING;

static ztd_sink_receiver_nonblocking_t ztd_sink_node_nonblocking_receiver(ztd_sink_tap_t *tap) {
    return ^int32_t(const AudioTimeStamp *timestamp, uint32_t frames, const AudioBufferList *buffers) ZTD_NONBLOCKING {
        (void)timestamp;
        return ztd_sink_tap_receive(tap, buffers, frames);
    };
}

/* The same body for the classic initialiser, whose block type promises nothing. */
static ztd_sink_receiver_t ztd_sink_node_classic_receiver(ztd_sink_tap_t *tap) {
    return ^int32_t(const AudioTimeStamp *timestamp, uint32_t frames, const AudioBufferList *buffers) {
        (void)timestamp;
        return ztd_sink_tap_receive(tap, buffers, frames);
    };
}

bool ztd_sink_node_has_realtime_safe_initialiser(void) {
    if (@available(iOS 27.0, *)) return true;
    return false;
}

ztd_sink_receiver_t ztd_sink_node_receiver(ztd_sink_tap_t *tap, bool realtime_safe) {
    if (!tap) return nil;
    /* A non-blocking block is also a block of the plain type: dropping the promise is allowed. */
    if (realtime_safe) return ztd_sink_node_nonblocking_receiver(tap);
    return ztd_sink_node_classic_receiver(tap);
}

AVAudioSinkNode *ztd_sink_node_create(ztd_sink_tap_t *tap, bool realtime_safe) {
    static const char holder_key = 0;
    if (!tap) return nil;
    AVAudioSinkNode *node = nil;
    if (realtime_safe) {
        if (@available(iOS 27.0, *)) {
            node = [[AVAudioSinkNode alloc] initWithRealtimeSafeReceiverBlock:ztd_sink_node_nonblocking_receiver(tap)];
        }
    }
    if (!node) node = [[AVAudioSinkNode alloc] initWithReceiverBlock:ztd_sink_node_classic_receiver(tap)];
    if (node) {
        objc_setAssociatedObject(node, &holder_key, [[ZTDSinkTapHolder alloc] initWithTap:tap],
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return node;
}
