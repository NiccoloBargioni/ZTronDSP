#include "ztd_thread.h"

#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <math.h>
#include <pthread.h>

/* Scheduling helpers for the analysis thread (WP-226, RT-9). */

/* mach_absolute_time carries no `nonblocking` attribute of its own: the audited allow-list
   (ztd_vdsp.h) re-declares it with one, beside the vDSP routines. */
#include "ztd_vdsp.h"

/* Seconds per tick of the clock. Read once, when the image is loaded: mach_timebase_info is not
   non-blocking, and ztd_thread_now must be. Until then, and if the system should ever fail to
   answer, a tick is a nanosecond, which is the clock's definition where the timebase is 1 / 1. */
static double ztd_seconds_per_tick = 1e-9;

__attribute__((constructor)) static void ztd_thread_read_timebase(void) {
    mach_timebase_info_data_t timebase = {1, 1};
    mach_timebase_info(&timebase);
    if (timebase.denom != 0) ztd_seconds_per_tick = (double)timebase.numer / (double)timebase.denom * 1e-9;
}

/* A duration in ticks, for the kernel. False when it is not a duration at all, or does not fit
   the 32 bits the policy has for it. */
static bool ztd_ticks(double seconds, uint32_t *ticks) {
    if (!(seconds >= 0.0) || !isfinite(seconds)) return false;
    const double value = seconds / ztd_seconds_per_tick;
    if (!(value < 4294967295.0)) return false;
    *ticks = (uint32_t)(value + 0.5);
    return true;
}

/* The priority the calling thread had before its first time-constraint policy: what a clear
   goes back to. −1 while there is none. One per thread. */
static _Thread_local int32_t ztd_priority_before = -1;

/* The calling thread's base priority as the kernel holds it, or −1. */
static int32_t ztd_thread_base_priority(void) {
    thread_extended_info_data_t info;
    mach_msg_type_number_t count = THREAD_EXTENDED_INFO_COUNT;
    // coverage:ignore(the kernel refuses a thread that is gone, a flavour it does not know or a short count; the calling thread asking with its own count is none of these)
    if (thread_info(pthread_mach_thread_np(pthread_self()), THREAD_EXTENDED_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) {
        return -1;
    }
    return info.pth_priority;
}

bool ztd_thread_set_time_constraint(double period, double computation, double constraint) {
    thread_time_constraint_policy_data_t policy;
    if (!ztd_ticks(period, &policy.period) || !ztd_ticks(computation, &policy.computation) ||
        !ztd_ticks(constraint, &policy.constraint)) {
        return false;
    }
    /* Where the thread stands now is where a clear takes it back to. */
    if (!ztd_thread_get_time_constraint(NULL)) ztd_priority_before = ztd_thread_base_priority();
    policy.preemptible = TRUE;
    /* Whether the figures make a policy the scheduler can honour is for the kernel to say. When
       it refuses, it restores the thread's quality of service itself; nothing is undone here. */
    const kern_return_t result = thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                                                   (thread_policy_t)&policy, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    return result == KERN_SUCCESS;
}

bool ztd_thread_get_time_constraint(double *period) {
    thread_time_constraint_policy_data_t policy;
    mach_msg_type_number_t count = THREAD_TIME_CONSTRAINT_POLICY_COUNT;
    boolean_t is_default = FALSE;
    const kern_return_t result = thread_policy_get(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY,
                                                   (thread_policy_t)&policy, &count, &is_default);
    /* The kernel answers with the default figures, and says so, for a thread that has no
       time-constraint policy. */
    if (result != KERN_SUCCESS || is_default) return false;
    if (period) *period = (double)policy.period * ztd_seconds_per_tick;
    return true;
}

void ztd_thread_clear_time_constraint(void) {
    /* A thread without a time-constraint policy is left as it is. Making it a time-share thread
       by hand would take it out of its quality-of-service class, and the system lets no thread
       back into a class it has left. */
    if (!ztd_thread_get_time_constraint(NULL)) return;
    const thread_act_t thread = pthread_mach_thread_np(pthread_self());
    thread_extended_policy_data_t policy;
    policy.timeshare = TRUE;
    thread_policy_set(thread, THREAD_EXTENDED_POLICY, (thread_policy_t)&policy, THREAD_EXTENDED_POLICY_COUNT);
    /* The class is gone for good; the priority it gave is not. The thread gets it back as a
       precedence over the time-share base, measured from that base. */
    thread_precedence_policy_data_t precedence;
    precedence.importance = 0;
    thread_policy_set(thread, THREAD_PRECEDENCE_POLICY, (thread_policy_t)&precedence, THREAD_PRECEDENCE_POLICY_COUNT);
    const int32_t base = ztd_thread_base_priority();
    if (base >= 0 && ztd_priority_before > base) {
        precedence.importance = ztd_priority_before - base;
        thread_policy_set(thread, THREAD_PRECEDENCE_POLICY, (thread_policy_t)&precedence, THREAD_PRECEDENCE_POLICY_COUNT);
    }
}

double ztd_thread_now(void) ZTD_NONBLOCKING {
    return (double)mach_absolute_time() * ztd_seconds_per_tick;
}

void ztd_thread_sleep_until(double deadline) {
    if (!(deadline > 0.0) || !isfinite(deadline)) return;
    mach_wait_until((uint64_t)(deadline / ztd_seconds_per_tick));
}
