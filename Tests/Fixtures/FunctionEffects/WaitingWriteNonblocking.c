/* Fixture of WP-222. The lossless write waits for space, so it sleeps: it is for reader threads
   only. A non-blocking function that reaches it MUST NOT build with the flags the manifest
   gives the C target. */

#include "ztd_ring.h"

uint32_t ztd_fixture_waiting(ztd_ring_t *ring, const float *const *channels, uint32_t frames) ZTD_NONBLOCKING {
    return ztd_ring_write_waiting(ring, channels, frames);
}
