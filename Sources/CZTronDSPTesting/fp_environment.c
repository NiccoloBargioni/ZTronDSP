#include "CZTronDSPTesting.h"

#include <fenv.h>
#include <string.h>

uint64_t ztdt_floating_point_environment(void) {
    fenv_t environment;
    memset(&environment, 0, sizeof(environment));
    fegetenv(&environment);
    /* FNV-1a over the bytes of the saved environment. */
    const unsigned char *bytes = (const unsigned char *)&environment;
    uint64_t digest = 1469598103934665603ull;
    for (size_t i = 0; i < sizeof(environment); i++) {
        digest ^= bytes[i];
        digest *= 1099511628211ull;
    }
    return digest;
}
