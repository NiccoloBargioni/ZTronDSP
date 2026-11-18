Currency check (§7.3), 2026-11-15: the registered source of this row was confirmed from the specification's register (§7.2 row 3, "IIR filtering: cascaded biquads, `vDSP_biquad` in single precision": Apple vDSP; Oppenheim & Schafer). No literature search was possible offline, so none was made.

Search of §7.3, made afterwards with network access on 2026-11-15: see `currency-2026-11.md`, row 3. Outcome: the selected algorithm is still current; what the search found beside it, if anything, is in `Docs/Process/changes/CR-020.md`.

# Biquad cascade, single precision (WP-208)

Stability register row 3. Code: `Sources/CZTronDSP/ztd_biquad.c`. Tests: `Tests/CZTronDSPTests/BiquadKernelTests.swift` (and `DoubleBiquadKernelTests.swift` for the comparisons with double precision). Figures are from the iOS 27.0 simulator on the host of §3, and are the same in Debug and in Release.

## Hazard

1. **Round-off near z = 1.** A recursive section amplifies the rounding of its own state by a factor that grows as its poles approach the unit circle: low cutoffs, high orders.
2. **Block-size dependence.** `vDSP_biquad` filters four frames at a time and the remaining one to three by another path that rounds differently. It also lines its groups of four up with the *output* address: into a buffer that is not 16-byte aligned it rounds differently again.
3. **Subnormal tails.** With silence at its input a cascade decays through the subnormal range (some 300 frames for the fixture below) before it reaches zero.
4. **State hygiene against badly scaled sections.** RT-6 clears every state value below 1e-20. A section that legitimately works below that level loses its memory at the end of every block.

## Bound or measured behaviour

Fixture of the acceptance: Butterworth high-pass, 1 kHz, order 4, 48 kHz, sections from SciPy (`KernelFixtures.acceptance[0]`).

| Measurement | vDSP_biquad | C loop |
|---|---|---|
| Impulse response against a double-precision reference (acceptance: 1e-5) | 1.5e-6 | 2.4e-7 |
| Full-scale white noise against the reference, relative to the output's peak, orders 2, 4, 6, 8 at 1 kHz | 8.6e-6, 8.0e-6, 1.4e-5, 1.7e-5 | 2.0e-6, 2.5e-6, 3.5e-6, 4.8e-6 |
| Impulse response, blocks of 1 and of 7 against 512 (acceptance: −100 dB) | −115.1 dB, −128.2 dB | identical |
| Full-scale noise, blocks of 1 and of 7 against 512 | −100.3 dB, −99.2 dB | identical |
| Blocks of 64, 128, 256 against 512 (any multiple of four frames) | identical | identical |

E-30 gives 2e-6 for the second row; on full-scale noise `vDSP_biquad` is four to eight times that, and the plain C loop is at one to two and a half times it. E-30's block-size figure for the 90 Hz, order 8 high-pass of the stress library (`hp-90Hz-48k-order8`), −61 dB, is confirmed: −59.4 dB on noise, blocks of 7 against 512.

The single-against-double deviation of §6.3.8 (impulse and seeded noise, 4 096 samples, relative to the output's peak; REAL-3 chooses double above −100 dB), with `vDSP_biquad` as the single path: `hp-1kHz-48k-order4` −98.4 dB, `hp-90Hz-48k-order8` −61.5 dB, `hp-20Hz-96k-order8` −33.1 dB, `hp-10Hz-44k1-order2` −53.9 dB, `lp-0.45fs-48k-order8` −107.6 dB, `hp-0.45fs-44k1-order4` −120.8 dB, `lp-0.49fs-48k-order2` −94.1 dB. Note that the acceptance fixture itself is above −100 dB: by REAL-3's rule as written it would be sent to the double kernel.

Hazard 4, on `lp-10Hz-192k-order8` as SciPy returns it (the whole gain, 5e-31, in the first section, which then works 23 decades below the signal): the kernel's output is off by the full scale of the reference (0 dB). With the gain spread over the sections (every section at unity gain at 0 Hz) the hazard is gone. Shown by `DoubleBiquadKernelTests.stateHygieneNeedsEverySectionToWorkNearTheLevelOfTheSignal`.

## Mitigation

- **Precision is chosen by measurement** (REAL-3, WP-433); this kernel is the single-precision side of that choice and the figures above are its measured accuracy. Sections arrive with the poles nearest the unit circle last (the designer's order; SciPy's fixtures have it).
- **The output does not depend on the caller's buffer.** A block whose output is not 16-byte aligned is filtered into the kernel's own aligned storage and copied; every call to `vDSP_biquad` has an aligned output and at most 1 024 frames, so both ways give the same floats. Shown by `theOutputDoesNotDependOnWhereTheCallersBufferLies`. What remains of hazard 2 is `vDSP_biquad`'s own: blocks that are not a multiple of four frames differ by round-off.
- **State hygiene (RT-6).** At the end of each block every value of the delay lines below 1e-20 is set to zero (`ztd_flush_state`). The floating-point environment is not touched.
- Hazard 4 is not this kernel's to mitigate: the rule is the specification's, and the remedy is at design time (spread the gain over the sections). The kernel header states the requirement.

## Stress test

`BiquadKernelTests.aDecayingTailReachesExactZeroAndLeavesNoSubnormalBehind`, on the `impulse` and `decaying-tail` signals of `StressFixture.signals` (WP-016), for both implementations: after the input has ended the output contains no subnormal value, reaches exact zero within two blocks of falling below 1e-20, and stays there. With the flush removed from the `vDSP_biquad` path the test fails (the tail passes through the subnormal range). Checked by making exactly that change, 2026-11-15.
