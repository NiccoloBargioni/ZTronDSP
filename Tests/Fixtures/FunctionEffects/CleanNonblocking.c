/* Fixture of WP-201 and WP-222. Non-blocking functions that stay within the rules: they call an
   allow-listed vDSP function, a builtin, and the ring's non-blocking write. This file builds
   with the flags the manifest gives the C target. */

#include "ztd_ring.h"
#include "ztd_vdsp.h"

void ztd_fixture_clean(const float *in, float *out, float gain, uint32_t frames) ZTD_NONBLOCKING {
    vDSP_vsmul(in, 1, &gain, out, 1, frames);
    memcpy(out, in, sizeof(float));
}

uint32_t ztd_fixture_clean_write(ztd_ring_t *ring, const float *const *channels, uint32_t frames) ZTD_NONBLOCKING {
    return ztd_ring_write(ring, channels, frames);
}
