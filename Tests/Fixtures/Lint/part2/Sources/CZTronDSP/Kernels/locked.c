#include <os/lock.h>

static os_unfair_lock_t the_lock;                    // !! RT-7
void bad(void) { os_unfair_lock_lock(the_lock); }    // !! RT-7
