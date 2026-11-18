/* Fixture of WP-201. A non-blocking function that allocates. With the flags the manifest gives
   the C target this file MUST NOT build; without them it builds. */

#include <stdlib.h>

#include "ztd_base.h"

float *ztd_fixture_allocating(uint32_t frames) ZTD_NONBLOCKING {
    /* This is what the attribute exists to catch: the audio thread asking the heap for memory. */
    return (float *)malloc((size_t)frames * sizeof(float));
}
