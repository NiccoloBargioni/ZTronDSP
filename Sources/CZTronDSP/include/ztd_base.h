#ifndef ZTD_BASE_H
#define ZTD_BASE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* A function that may run on the audio I/O thread or in the analysis thread's steady state.
   Under -Werror=function-effects clang checks that it allocates nothing and calls only other
   non-blocking functions (RT-1, RT-7 layer 1, E-03). A function WITHOUT this attribute belongs
   to the control context: it may allocate, free and lock, and must never be called from one
   that has it. */
#define ZTD_NONBLOCKING __attribute__((nonblocking))

/* The version of the kernel ABI (§5.11.1). It changes only by change request. */
#define ZTD_ABI_VERSION 1u

/* ZTD_ABI_VERSION as the library was built with it, for a kernel that checks it at run time.
   Any thread; does not allocate. */
uint32_t ztd_abi_version(void) ZTD_NONBLOCKING;

/* Which implementation of a primitive a kernel is bound to when it is created (§7.4, SEL-3).
   The choice is made once, on the control context; the hot path holds the chosen function and
   makes no size test. */
typedef enum ztd_implementation {
    ZTD_IMPLEMENTATION_NATIVE = 0,     /* a plain C loop */
    ZTD_IMPLEMENTATION_ACCELERATE = 1, /* vDSP */
} ztd_implementation_t;

/* An offset, in bytes, for the start of a newly allocated sample buffer: a multiple of 64 from
   64 to 3 904, different for buffers allocated one after another. Buffers that one loop reads
   and writes must not sit a whole number of pages apart (4K aliasing: each load then waits on a
   store it only seems to depend on); giving every buffer its own place within a page rules that
   out whatever the allocator does. Control context. */
size_t ztd_buffer_color(void);

/* State values whose magnitude is below this are set to zero at the end of each block, so no
   kernel leaves denormal state behind (RT-6). */
#define ZTD_STATE_FLOOR 1e-20

#ifdef __cplusplus
}
#endif

#endif /* ZTD_BASE_H */
