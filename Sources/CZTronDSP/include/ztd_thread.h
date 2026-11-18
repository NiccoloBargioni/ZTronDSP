#ifndef ZTD_THREAD_H
#define ZTD_THREAD_H

#include "ztd_base.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Scheduling helpers for the analysis thread (WP-226, RT-9). */

/* Asks for a Mach time-constraint policy for the calling thread: `period` is the poll interval,
   `computation` the time one turn needs, `constraint` the latest it may finish, in seconds.
   Returns true when the policy was granted. A refused request (figures the scheduler cannot
   honour, such as more computation than fits before the constraint, or values that are not
   durations) returns false and changes nothing: the thread keeps its quality of service, or
   the policy an earlier request was granted; the engine reports it. On the host of §3 the
   scheduler grants a computation between 50 µs and 50 ms.
   What the kernel keeps: the period and the constraint as given, and the computation as given
   when it is at least half the constraint; a smaller computation is raised to half the
   constraint (observed on the host of §3). A granted policy takes the thread out of its
   quality-of-service class: the two do not coexist. */
bool ztd_thread_set_time_constraint(double period, double computation, double constraint);

/* Reads the calling thread's time-constraint policy back. Returns true when one is in force and
   fills in its period, in seconds (to within one tick of the clock); false, with `period`
   untouched, when none is. `period` may be NULL. */
bool ztd_thread_get_time_constraint(double *period);

/* Ends the calling thread's time-constraint policy: the thread is a time-share thread again, at
   the priority it had before its first such policy. It is not put back into a quality-of-service
   class, because the system lets no thread return to a class it has left. A thread that has no
   time-constraint policy is left exactly as it is, class and priority included. */
void ztd_thread_clear_time_constraint(void);

/* The current time, in seconds, on the monotonic clock the thread paces itself with. */
double ztd_thread_now(void) ZTD_NONBLOCKING;

/* Sleeps until `deadline` on that clock (mach_wait_until). Not non-blocking: the analysis thread
   calls it between turns, never inside one. A deadline that has passed, or is not a time at all
   (zero, negative, not finite), returns at once. */
void ztd_thread_sleep_until(double deadline);

#ifdef __cplusplus
}
#endif

#endif /* ZTD_THREAD_H */
