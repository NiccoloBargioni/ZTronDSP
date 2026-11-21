#ifndef ZTD_VDSP_H
#define ZTD_VDSP_H

/* The audited vDSP allow-list (WP-201, E-03, E-07).

   vDSP's declarations carry no `nonblocking` attribute, so clang would reject every call to them
   from a non-blocking function. Each function below is re-declared with the attribute, which
   compiles clean (E-03) and is a claim: this entry point does not allocate, lock or block when
   it is given a setup created beforehand. The claim rests on the measurements of E-07 and is
   re-checked at run time by the allocation audit of every kernel (RT-7 layer 3), on every OS of
   the test matrix.

   Rules for this file:
     - one entry per vDSP function the C target calls from non-blocking code, and no others;
     - an entry is added only together with a kernel test that runs it inside the allocation audit;
     - setup creation and destruction are never listed: they belong to the control context.

   A public header (EXT-3): a kernel written outside the package includes it, by name, and calls
   the entry points listed here from its own non-blocking code without declaring them again. An
   entry point that is not listed has not been audited by this package: a kernel that calls one
   declares it itself and audits it itself, as the rules above say. */

#include <Accelerate/Accelerate.h>
#include <string.h>

#include "ztd_base.h"

/* Re-declares a system function with ZTD_NONBLOCKING: one entry of the allow-list. */
#define ZTD_ALLOW(declaration) extern declaration ZTD_NONBLOCKING

/* memcpy, memmove and memset need no entry: clang knows them as builtins that do not block, and
   <string.h> defines them as macros, so they cannot be re-declared. */

/* The one system function outside vDSP that non-blocking code of this target calls.
   mach_absolute_time reads the commpage: no system call, no lock, no allocation. Audit:
   ThreadTests, the allocation audit of ztd_thread_now. */
ZTD_ALLOW(uint64_t mach_absolute_time(void));

/* Each entry names the audit that runs it (Tests/CZTronDSPTests).

   vDSP.h declares its functions inside an assume-nonnull region, and spells the nullability of
   the pointer-to-pointer arguments out. The re-declarations sit in the same kind of region, so
   each has exactly the type of the original. */
#pragma clang assume_nonnull begin

/* Scaling and element-wise product (gain kernel: a constant gain, and a rendered ramp).
   Audit: GainKernelTests.processingAndCommandsAreAllocationFree. */
ZTD_ALLOW(void vDSP_vsmul(const float *__A, vDSP_Stride __IA, const float *__B, float *__C, vDSP_Stride __IC, vDSP_Length __N));
ZTD_ALLOW(void vDSP_vmul(const float *__A, vDSP_Stride __IA, const float *__B, vDSP_Stride __IB, float *__C, vDSP_Stride __IC, vDSP_Length __N));

/* Biquad cascades, single precision: one setup with a delay line per channel, and its setter
   (iOS 15.0, E-08). Audit: BiquadCoefficientUpdateTests.processingAndCoefficientUpdatesAreAllocationFree. */
ZTD_ALLOW(void vDSP_biquad(const struct vDSP_biquad_SetupStruct *__Setup, float *__Delay, const float *__X, vDSP_Stride __IX, float *__Y, vDSP_Stride __IY, vDSP_Length __N));
ZTD_ALLOW(void vDSP_biquad_SetCoefficientsDouble(vDSP_biquad_Setup __setup, const double *__coeffs, vDSP_Length __start_sec, vDSP_Length __nsec));

/* Biquad cascades, single precision, one setup for all channels: processing, the setter (iOS 9)
   and the state reset. Audit: MultichannelBiquadKernelTests.processingUpdatesAndResetsAreAllocationFree. */
ZTD_ALLOW(void vDSP_biquadm(vDSP_biquadm_Setup __Setup, const float * __nonnull * __nonnull __X, vDSP_Stride __IX, float * __nonnull * __nonnull __Y, vDSP_Stride __IY, vDSP_Length __N));
ZTD_ALLOW(void vDSP_biquadm_SetCoefficientsDouble(vDSP_biquadm_Setup __setup, const double *__coeffs, vDSP_Length __start_sec, vDSP_Length __start_chn, vDSP_Length __nsec, vDSP_Length __nchn));
ZTD_ALLOW(void vDSP_biquadm_ResetState(vDSP_biquadm_Setup __setup));

/* Correlation with a filter (direct FIR, interpolator phases, the head of the partitioned
   kernel) and its decimating form (decimator). Audits: FIRKernelTests.processingAndTapChangesAreAllocationFree,
   and processingIsAllocationFree of InterpolatorKernelTests, PartitionedKernelTests and
   DecimatorKernelTests. */
ZTD_ALLOW(void vDSP_conv(const float *__A, vDSP_Stride __IA, const float *__F, vDSP_Stride __IF, float *__C, vDSP_Stride __IC, vDSP_Length __N, vDSP_Length __P));
ZTD_ALLOW(void vDSP_desamp(const float *__A, vDSP_Stride __DF, const float *__F, float *__C, vDSP_Length __N, vDSP_Length __P));

/* The real transform, with setups created beforehand (partitioned convolution).
   Audit: PartitionedKernelTests.processingIsAllocationFree. */
ZTD_ALLOW(void vDSP_DFT_Execute(const struct vDSP_DFT_SetupStruct *__Setup, const float *__Ir, const float *__Ii, float *__Or, float *__Oi));

/* Element-wise minimum and maximum (lane exchange).
   Audit: LaneExchangeTests.bothImplementationsAreAllocationFree. */
ZTD_ALLOW(void vDSP_vmin(const float *__A, vDSP_Stride __IA, const float *__B, vDSP_Stride __IB, float *__C, vDSP_Stride __IC, vDSP_Length __N));
ZTD_ALLOW(void vDSP_vmax(const float *__A, vDSP_Stride __IA, const float *__B, vDSP_Stride __IB, float *__C, vDSP_Stride __IC, vDSP_Length __N));

#pragma clang assume_nonnull end

#endif /* ZTD_VDSP_H */
