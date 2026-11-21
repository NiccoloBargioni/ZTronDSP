#ifndef ZTD_KERNELS_H
#define ZTD_KERNELS_H

#include "ztd_kernel.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------------------------
   The stock kernels (M2). Every constructor runs on the control context, allocates everything
   the kernel will ever need, and returns a kernel whose `process` is NULL when it could not or
   when its arguments make no kernel: no channels, no taps, a factor of zero, a value that is not
   a number (ztd_kernel_is_null). Every kernel:
     - takes blocks of any size from 0 frames up, and `channels` as it was created with;
     - carries its state across calls and clears it on `reset`;
     - is allocation-free and lock-free in `process`, `command` and `reset`;
     - ignores a command that is not for it: another kind, another count, no payload, NULL.

   Block sizes. The output stream of a kernel does not depend on how its input is cut into
   blocks, bit for bit, nor on where the caller keeps its buffers, with three exceptions. Two
   are Accelerate's and are stated at the kernels concerned: the single-precision biquads on vDSP
   (bit for bit for blocks of a multiple of four frames, within round-off otherwise) and the
   partitioned convolution (within -100 dB). The third is state hygiene's, below, and holds
   for the recursive kernels.

   State hygiene (RT-6). No kernel leaves a state value below ZTD_STATE_FLOOR in magnitude
   behind at the end of a block. The recursive kernels (biquads, alpha-beta) set such values to
   zero then (ztd_flush_state); they do so value by value, which is harmless only while every
   section of a cascade works near the level of the signal (see the biquads). The kernels with an
   input history (FIR, decimator, interpolator, partitioned) take a sample below the floor as
   zero when it enters, so their histories never hold one.

   What that means for block sizes. RT-6 fixes the flush at the end of each block, so a
   recursive kernel is its recurrence with every state value below the floor set to zero at
   the end of each of its blocks: bit for bit that, for any cut of the input. Two cuts of one
   input therefore give the same output, bit for bit, as long as neither has cleared a value
   that the other kept, which is so whenever no state value is below the floor, and not zero,
   at the end of a block; from the frame at which one of them has, the outputs differ by what
   the cleared values would have come to, as the rest of the kernel passes it on. A section
   that starts from silence, or decays to it, passes through such values. Measured (the
   double-precision cascade, a 10 Hz low-pass of order 8 at 192 kHz with its gain spread over
   the sections, on 8 192 frames of full-scale noise): blocks of 1 and of 512 frames differ
   from the second frame on, by at most 4.5e-13 where the output peaks at 2.5e-5, and a cut
   that shares the first one's blocks for the first 2 048 frames gives the first one's output.
   The kernels with an input history are not affected: they clean samples, not blocks.
   --------------------------------------------------------------------------------------------- */

/* --- Gain (WP-207) ---------------------------------------------------------------------------
   out = in · g, per channel. A changed gain ramps linearly to its target over `ramp_frames`
   frames, continuous across blocks, and lands on the target exactly: with `left` frames of the
   move still to come after a frame, its gain is target − increment · left, a closed form of the
   frame's place in the ramp. A new target during a move starts a move of the full length from
   the gain in force. A reset keeps the gain last asked for and drops the move towards it.
     gains        `channels` values, or NULL for unity
     ramp_frames  frames a change takes; 0 jumps
     implementation  a C loop, or vDSP_vsmul with vDSP_vmul over the rendered ramp; bound here
                  (SEL-3). Both give the same floats as the scalar loop. (vDSP_vrampmul is not
                  used: its ramp does not match its documented loop bit for bit.)
   ZTD_COMMAND_SET_VALUES: `count` is 1 (one gain for every channel, in scalar[0]) or `channels`
   (float gains at `values`). */
ztd_kernel_t ztd_gain_create(uint32_t channels, const float *gains, uint32_t ramp_frames,
                             ztd_implementation_t implementation);

/* --- Biquad cascade, single precision (WP-208, WP-209) ---------------------------------------
   `sections` second-order sections in series, each as five doubles b0 b1 b2 a1 a2 (a0 = 1):
       y[n] = b0·x[n] + b1·x[n−1] + b2·x[n−2] − a1·y[n−1] − a2·y[n−2]
   ZTD_IMPLEMENTATION_ACCELERATE runs on vDSP_biquad; ZTD_IMPLEMENTATION_NATIVE on a C loop
   (it leads below about 4 frames per block, E-26). The C loop is the recurrence above in
   Float32, frame by frame: block-size invariant bit for bit, but for what state hygiene
   clears at the end of a block (see "What that means for block sizes"). vDSP_biquad filters
   four frames at a time: blocks of any multiple of four frames give the same floats, other
   sizes differ by
   round-off (about −100 dB of the peak on full-scale noise for a 1 kHz high-pass of order 4).
   Neither depends on how the caller's buffers are aligned.
   ZTD_COMMAND_SET_VALUES: 5·sections doubles at `values`, set in place; the filter keeps its
   memory (vDSP_biquad_SetCoefficientsDouble, E-08).
   `settling_frames` is the time the slowest pole of the coefficients given here takes to decay
   by 100 dB, at most 2^24 frames.
   The gain of a cascade must be spread over its sections: a section that works more than twenty
   decades below the signal (the first section of a 10 Hz low-pass of order 8 at 192 kHz, when
   it carries the whole gain) has its memory cleared by RT-6 at the end of every block. */
ztd_kernel_t ztd_biquad_create(uint32_t channels, uint32_t sections, const double *coefficients,
                               ztd_implementation_t implementation);

/* --- Biquad cascade, single precision, many channels (WP-210) --------------------------------
   The same cascade on vDSP_biquadm: one setup for all channels. Coefficients are shared by the
   channels. ZTD_COMMAND_SET_VALUES as above. `process` needs all `channels` buffers.
   Each channel equals the mono kernel to the accuracy of single precision, not bit for bit:
   vDSP_biquadm and vDSP_biquad are two routines (measured on the fixture of WP-208: within 1e-5
   on the impulse response; on full-scale noise −115 dB from a double-precision reference, −110 dB
   from the mono C loop, −97 dB from the mono vDSP_biquad kernel, which is itself that far from
   the reference). A channel's output does not depend on the other channels' signals. Blocks of a
   multiple of eight frames give the same floats; other sizes differ by round-off (−111 dB).
   vDSP_biquadm keeps its memory inside the setup, where single values cannot be flushed. The
   kernel keeps it clean channel by channel: a channel whose input and output have stayed below
   ZTD_STATE_FLOOR for 2·sections + 2 frames, the length of the cascade's memory, and whose next
   block is quiet too, is parked. It then runs on coefficients of zero, which empty its memory
   within two frames, and its output is exact zeros; it gets its coefficients back before the
   first block that carries signal again. A channel that is silent while another plays therefore
   leaves nothing behind either. When all channels are that quiet at once the memory is cleared
   as a whole. */
ztd_kernel_t ztd_biquadm_create(uint32_t channels, uint32_t sections, const double *coefficients);

/* --- Biquad cascade, double precision (WP-211) -----------------------------------------------
   The package's own kernel: transposed direct form II with double state and coefficients,
   Float32 samples in and out. Block-size invariant bit for bit, but for what state hygiene
   clears at the end of a block (see "What that means for block sizes": the case measured there
   is this kernel's). ZTD_COMMAND_SET_VALUES:
   5·sections doubles at `values`, exchanged at the block boundary; the state is kept.
   `settling_frames` and the rule about the gain of the sections are those of the single-precision
   kernel. */
ztd_kernel_t ztd_biquad_double_create(uint32_t channels, uint32_t sections, const double *coefficients);

/* --- Direct FIR (WP-212) ---------------------------------------------------------------------
   y[n] = Σ taps[k]·x[n − k], on a history plus vDSP_conv. `latency_frames` is what the caller
   states (a linear-phase filter has (count − 1) / 2); the kernel reports it, it does not add it.
   `settling_frames` is count − 1. Block-size invariant bit for bit: the kernel computes in cells
   of 64 frames counted from its first frame, so vDSP_conv is only ever called in one shape; a
   block that is not whole cells computes a cell more than once.
   ZTD_COMMAND_SET_VALUES: `count` floats at `values`, the same length as at creation; old and new
   taps are cross-faded over `fade_frames` frames (0 is taken as 1): for those frames the output
   is old + (new − old)·g, g as ztd_crossfade_mix defines it, and from then on the new filter's.
   New taps during a fade fade in from the blend that sounds at that moment. A reset lands on the
   taps last asked for. */
ztd_kernel_t ztd_fir_create(uint32_t channels, const float *taps, uint32_t count,
                            uint32_t latency_frames, uint32_t fade_frames);

/* --- Decimator (WP-213) ----------------------------------------------------------------------
   Low-pass by `taps`, then keep every `factor`-th sample (vDSP_desamp), the first frame after
   creation or a reset included; the phase is carried across blocks, so the output equals
   filter-then-subsample for any block sizes, bit for bit (cells of 16 output frames). Returns
   frames / factor frames or one more: `out` needs room for (frames + factor − 1) / factor.
   `factor` is 1 … 4 096. `latency_frames`, in input frames, is the caller's to state;
   `settling_frames` is count − 1 input frames. */
ztd_kernel_t ztd_decimator_create(uint32_t channels, uint32_t factor, const float *taps, uint32_t count,
                                  uint32_t latency_frames);

/* --- Interpolator (WP-223) -------------------------------------------------------------------
   Insert `factor − 1` zeros after each sample, then low-pass by `taps` with gain `factor`, as a
   polyphase filter: `factor` short filters, one per output phase, one vDSP_conv per phase with
   an output stride. Equals zero-stuff-then-filter, with the result multiplied by `factor`: the
   kernel applies that gain itself (folded into the phase taps), so `taps` is a low-pass with
   unity gain at 0 Hz and a constant comes out at its own level. Block-size invariant bit for bit
   (cells of 64 input frames). Returns frames · factor frames: `out` needs room for that many.
   `factor` is 1 … 4 096. `latency_frames` is the caller's to state; `settling_frames` is one
   phase less a frame, ⌈count / factor⌉ − 1 input frames. */
ztd_kernel_t ztd_interpolator_create(uint32_t channels, uint32_t factor, const float *taps, uint32_t count,
                                     uint32_t latency_frames);

/* --- Subsample and zero-stuff, no filter (WP-227) --------------------------------------------
   Keep every `factor`-th sample starting at `phase` (taken modulo `factor`); insert `factor − 1`
   zeros after each sample. The phase is carried across blocks, and a reset starts it again.
   `factor` is 1 … 4 096. These are the toolkit's subsampled(_:by:phase:) and upsampled(_:by:)
   for a stream. Subsample returns frames / factor frames or one more; zero-stuff frames · factor. */
ztd_kernel_t ztd_subsample_create(uint32_t channels, uint32_t factor, uint32_t phase);
ztd_kernel_t ztd_zero_stuff_create(uint32_t channels, uint32_t factor);

/* --- Partitioned convolution (WP-214, WP-215) ------------------------------------------------
   An FIR of `count` taps as a uniformly partitioned frequency-domain delay line (Wefers 2015).
   `partition` is the partition length, a power of two from 8 to 2^20; the transform length is
   twice that. Within −100 dB of the direct kernel, for any block sizes.
   The kernel adds no latency, whatever the blocks: `latency_frames` is what the caller states,
   as for the direct kernel, and `settling_frames` is count − 1. Input partitions lie on a grid
   counted from the kernel's first frame. A block that brings whole partitions on that grid is
   computed in the frequency domain alone (two transforms and count / partition spectral
   products per partition): that is the case to build for, with the partition equal to the block
   size or dividing it. Frames that arrive as part of a partition are computed at once all the
   same, from the first `partition` taps convolved directly plus the rest of the filter taken
   from the delay line (Gardner 1995), at the cost of that direct convolution. The two paths
   round differently, so the output for different block sizes agrees within the tolerance above,
   not bit for bit. */
ztd_kernel_t ztd_partitioned_create(uint32_t channels, const float *taps, uint32_t count, uint32_t partition,
                                    uint32_t latency_frames);

/* The spectra the partitioned kernel holds, for the test that they equal the DFT of each
   partition (WP-214): copies partition `index` of channel-independent kernel spectra into
   `real` and `imaginary` (partition + 1 bins each: bins 0 … partition of the transform of the
   partition zero-padded to 2·partition). Returns the number of partitions, ⌈count / partition⌉;
   0 for a kernel that is not a partitioned one. An index past the last, or a NULL buffer,
   copies nothing. Control context. */
uint32_t ztd_partitioned_spectrum(const ztd_kernel_t *kernel, uint32_t index, float *real, float *imaginary);

/* --- Alpha–beta tracker (WP-218) -------------------------------------------------------------
   Per sample z:  r = z − (x + dt·v);  x ← x + dt·v + alpha·r;  v ← v + (beta / dt)·r.
   Outputs the position x, or the velocity v when `output_velocity` is set. The two states are
   kept in double precision, so the output is the recurrence itself rounded to Float32, with a
   state below ZTD_STATE_FLOOR cleared at the end of each block (RT-6; see "What that means for
   block sizes").
   `time_step` (dt) is positive. A reset returns to the initial position and velocity. */
ztd_kernel_t ztd_alpha_beta_create(uint32_t channels, float alpha, float beta, float time_step,
                                   float initial_position, float initial_velocity, bool output_velocity);

/* --- Lane exchange (WP-219) ------------------------------------------------------------------
   The primitive of the median network: a[i], b[i] ← min(a[i], b[i]), max(a[i], b[i]). Both
   implementations give the same lanes, by one rule, the minimum and maximum of IEEE 754-2019:
   a NaN in either lane makes both NaN, and −0 orders below +0. `a` and `b` do not overlap. */
void ztd_lane_exchange_native(float *a, float *b, uint32_t count) ZTD_NONBLOCKING;
void ztd_lane_exchange_accelerate(float *a, float *b, uint32_t count) ZTD_NONBLOCKING;
typedef void (*ztd_lane_exchange_fn)(float *a, float *b, uint32_t count) ZTD_NONBLOCKING;
/* The function for an implementation, bound once when a plan is compiled (SEL-3). Anything
   that is not ZTD_IMPLEMENTATION_ACCELERATE gives the native one. */
ztd_lane_exchange_fn ztd_lane_exchange_function(ztd_implementation_t implementation);

/* --- State hygiene (WP-216, RT-6) ------------------------------------------------------------
   Sets to zero every value whose magnitude is below ZTD_STATE_FLOOR. The floating-point
   environment is not touched (E-03). */
void ztd_flush_state(float *state, uint32_t count) ZTD_NONBLOCKING;
void ztd_flush_state_double(double *state, uint32_t count) ZTD_NONBLOCKING;

/* --- Cross-fade (WP-217) ---------------------------------------------------------------------
   A linear fade of a fixed number of frames that may span blocks. The two weights sum to one at
   every sample, and the duration does not depend on the block size. */
typedef struct ztd_crossfade {
    uint32_t total;     /* frames the fade takes */
    uint32_t position;  /* frames already faded */
} ztd_crossfade_t;

/* Starts a fade of `frames` frames (at least 1). */
void ztd_crossfade_begin(ztd_crossfade_t *fade, uint32_t frames) ZTD_NONBLOCKING;
/* True once the fade has run its whole length. */
bool ztd_crossfade_is_done(const ztd_crossfade_t *fade) ZTD_NONBLOCKING;
/* Mixes the next `frames` frames: out = from·(1 − g) + to·g, with g rising linearly from just
   above 0 to exactly 1 at the fade's last frame; frames past the end of the fade are `to`.
   `out` may be `from` or `to`. Advances the fade. */
void ztd_crossfade_mix(ztd_crossfade_t *fade, const float *from, const float *to, float *out,
                       uint32_t frames) ZTD_NONBLOCKING;

#ifdef __cplusplus
}
#endif

#endif /* ZTD_KERNELS_H */
