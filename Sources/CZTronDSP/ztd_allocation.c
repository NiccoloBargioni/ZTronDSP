#include "ztd_internal.h"

#include <pthread.h>

/* The seam for the tests of failed creation (see ztd_internal.h). One counter per thread: how
   many more requests of this thread succeed before one is refused, plus one; nothing while none
   will be.

   The counter lives in a thread-specific slot, not in a `_Thread_local`. The system allocates
   the thread-local block of an image when a thread first touches it, so a constructor that
   asked here for the first time on its thread would have allocated, to a test that counts what
   a thread allocates and frees (and every atomic cell asks). A slot costs a thread nothing; it
   is filled only by a test that asks for a refusal. */

static pthread_key_t ztd_refusal_key;
static bool ztd_refusal_has_key = false;

/* When the image is loaded, before anything can ask. Without a key (the process has none left
   to give) every request is granted and a refusal cannot be asked for. */
__attribute__((constructor)) static void ztd_refusal_make_key(void) {
    ztd_refusal_has_key = pthread_key_create(&ztd_refusal_key, NULL) == 0;
}

bool ztd_may_allocate(void) {
    if (!ztd_refusal_has_key) return true;
    const intptr_t left = (intptr_t)pthread_getspecific(ztd_refusal_key);
    if (left == 0) return true;
    /* Down to nothing: one refusal, then back to normal. */
    pthread_setspecific(ztd_refusal_key, (void *)(left - 1));
    return left != 1;
}

/* Nothing in the package calls the two functions below: the tests look them up by name. `used`
   keeps the linker from discarding them as dead code. */

__attribute__((used)) void ztd_fail_allocation(int32_t index) {
    if (ztd_refusal_has_key) pthread_setspecific(ztd_refusal_key, (void *)(intptr_t)(index < 0 ? 0 : (intptr_t)index + 1));
}

__attribute__((used)) bool ztd_allocation_failure_is_pending(void) {
    return ztd_refusal_has_key && pthread_getspecific(ztd_refusal_key) != NULL;
}
