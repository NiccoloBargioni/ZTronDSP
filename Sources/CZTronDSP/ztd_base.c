#include "ztd_kernel.h"

#include <stdatomic.h>
#include "ztd_vdsp.h"

uint32_t ztd_abi_version(void) ZTD_NONBLOCKING {
    return ZTD_ABI_VERSION;
}

static uint32_t ztd_identity_process(void *state, const float *const *in, float *const *out, uint32_t channels,
                                     uint32_t frames) ZTD_NONBLOCKING {
    (void)state;
    for (uint32_t channel = 0; channel < channels; channel++) {
        memcpy(out[channel], in[channel], (size_t)frames * sizeof(float));
    }
    return frames;
}

static void ztd_identity_reset(void *state) ZTD_NONBLOCKING {
    (void)state;
}

ztd_kernel_t ztd_kernel_identity(void) {
    ztd_kernel_t kernel = {
        .process = ztd_identity_process,
        .command = NULL,
        .reset = ztd_identity_reset,
        .destroy = NULL,
        .state = NULL,
        .latency_frames = 0,
        .settling_frames = 0,
    };
    return kernel;
}

void ztd_kernel_destroy(ztd_kernel_t *kernel) {
    if (!kernel) return;
    if (kernel->destroy && kernel->state) kernel->destroy(kernel->state);
    kernel->state = NULL;
    kernel->process = NULL;
}

size_t ztd_buffer_color(void) {
    static _Atomic(uint32_t) next = 0;
    const uint32_t index = atomic_fetch_add_explicit(&next, 1, memory_order_relaxed);
    return (size_t)((index * 5u) % 61u + 1u) * 64u;
}
