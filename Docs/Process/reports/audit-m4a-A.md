# Audit of Verifier A, M4 first half (WP-401 … 421, 428a, 429, 430), lens N

| Field | Value |
|---|---|
| Audited | Verifier A's 25 reports `WP-<id>-A.md`, its evidence under `VerifierA/` and its logs under `.build/logs/` |
| Auditor | An independent auditor (agent). Not Verifier A, not Verifier B, not the implementer. Nothing that Verifier B wrote was read. |
| Revision | The tree that Verifier A reviewed: the main snapshot of 2026-11-17 20:05, after CR-023 |
| Simulator | `ztdsp-27-vm4aa`; every run was a Debug build |
| Date | 2026-11-17 |
| Read | Brief `23-verifier-a-m4a.md`; `ZTronDSP-SPEC.md`; `Docs/Process/changes/` (CR-001 … CR-023, plus CR-024 and CR-025 in main); `Docs/Numerics/`; the reports; `VerifierA/` |

## Outcome

- **The four blocking findings stand.** I reproduced each one myself through the public API, on a pristine tree. All four are blocking under §11.6.
  - A-1, A-2 and A-4 are confirmed.
  - A-3 is confirmed in part. Its core stands: a gain that underflows comes back as a filter of gain 0, with no error. Its subnormal sub-case is not a wrong result under any tolerance that applies.
- **The verdicts stand.**
  - Blocking: WP-402, 412, 413, 414, 418a, 418b, 419.
  - Pass: the other 18.
  - I spot-checked five pass verdicts (WP-415, 416, 417, 420 and 428a) on cases of my own, and all five hold.
- **Gaps in the verification (section 2):**
  - FIX-4 was not carried out for A-1.
  - The non-blocking rating of A-NB3 is not argued against NUM-1.
  - Ten reports do not show the non-finite-input edge case.
  - The WP-404 report shows no edge case at all.
  - Eighteen reports do not state the precision choice.

## 1 The blocking findings (duty 1)

| Finding | Packages | Rule | Verdict | Severity (§11.6) | Reproduced | Evidence (my runs; details below) |
|---|---|---|---|---|---|---|
| A-1 | WP-419 | §6.3.4, the row for the digital low-pass and the upper skirt of a digital band-pass (`SPEC:1068`); the WP-419 acceptance (`SPEC:2038`) | confirmed | blocking | yes | `repro-audit1`, octave 750 → 1 500 Hz at 48 kHz:<br>• Butterworth n = 24, 32, 64: +0.50372, +0.67162, +1.34325 dB/oct<br>• Chebyshev I: +0.51067, +0.68089, +1.36178 dB/oct<br>• controls n = 16 and 23: +0.33581 and +0.48273<br>The closed form adds 0.020988 dB/oct per order, so the bound fails from n = 24 for any bilinear design. No CR exists. |
| A-2 | WP-414, WP-418b | §11.6 "a result is wrong" (the reports cite §11.4) | confirmed | blocking | yes | `repro-audit1`: at order 512, 10 kHz / 48 kHz, Butterworth and Chebyshev I both return gain 0 and ‖H‖ = 0, with no error. The exact digital gains are 10^−161.575 and 10^−239.904. The running ratio alone is 10^−410.940. `audit-1`: \|H(0)\| is already off by 2.4·10⁻⁷ at order 395, and by 1.8·10⁻³ at order 400. |
| A-3 | WP-412, 413, 414, 418a, 418b | §11.6 "a result is wrong" (the reports cite §11.4) | confirmed in part | blocking | yes | `repro-audit1`: all five calls return gain 0 and ‖H‖ = 0 with no error; the overflow control throws. Stands: the zero filter. Not blocking: the subnormal sub-case (gain 3.13706·10⁻³¹⁸, relative error 7.31·10⁻⁸). That gain is the correctly rounded double, and STG-2's 10⁻⁹ covers only orders 1, 2, 5 and 8. |
| A-4 | WP-402 | NUM-1 (`SPEC:1005`) | confirmed | blocking | yes | `repro-audit1`: κ = inf for a double root and for an overflowing sum; `rootConditions` = [inf, inf]; `poleConditions` = [inf, inf]. `audit-1`: `analysis(sampleRate:).rootConditions.largest` = inf. No CR exempts κ. |

The sources were pristine for every run:

- `Sources/ZTronDSPDesign` and the specification are identical to main.
- `Sources/ZTronDSPCore` differs from main only in engine, compiler, feed and pipeline files that main changed after the snapshot. None of them is on the design path. `Units/RollOff.swift` is identical.
- Before my runs I took checksums of 1 126 files (Sources, Tests, Scripts, `Docs/Specification`, `Docs/Numerics`, `Docs/API` and `Package.swift`). They all match after the runs.
- After every run, `Tests` and `Sources` were identical to `.build/pristine`.

### A-1: the ±0.5 dB/oct bound fails from order 24

- **Rule and acceptance.**
  - §6.3.4 states the bound for the digital low-pass and for the upper skirt of a digital band-pass: "within ±0.5 dB per octave in octaves that end at or below f_s/32". The order is n = slope / 6.0206, with no order limit.
  - IN-7 calls this case "a stated approximation".
  - The WP-419 acceptance asks for "slope within ±0.5 dB/oct where the table says exact or bounded".
  - The orders that the code accepts go well past 24. `RollOff` accepts slopes of up to 4 096 orders (`RollOff.swift:87`), and the prototypes accept up to 512 (`AnalogPrototype.maximumOrder`).
- **Change request.** None covers this.
  - CR-014 item 3 only covers the rounding of 96 dB/oct.
  - Neither CR-001 … CR-023 in the reviewed tree nor CR-024 and CR-025 in main touches §6.3.4.
- **Reproduction** (`repro-audit1`: the verifier's own suite, run by me). The octave is 750 → 1 500 Hz at 48 kHz, which ends at f_s/32; the cutoff is 10 Hz.
  - Butterworth, n = 24, 32, 64: +0.5037185936686797, +0.6716247915582585, +1.343249583116517 dB/oct.
  - Chebyshev I 1 dB, same orders: +0.5106678742155282, +0.6808904989540565, +1.361780997908113 dB/oct.
  - The controls n = 16 and n = 23 give +0.33581 and +0.48273, and pass.
  - The roll-off maps to the order correctly.
- **Independent figure** (`audit_numbers.py`; closed forms only, no project code).
  - At that octave, the bilinear warping alone adds 20·log₁₀(tan(π/32) / (2·tan(π/64))) = 0.020988 dB/oct per order.
  - 0.5 / 0.020988 = 23.8, so the bound fails from n = 24 whatever the implementation.
  - The closed forms give +0.5037, +0.6716, +1.3432 (Butterworth) and +0.5107, +0.6809, +1.3618 (Chebyshev I), equal to the package's values to four decimals.
  - So the code is right, and the stated bound cannot be met.
- **Beyond the finding** (`audit-1`, my probe), more cases are outside the bound:
  - Bessel, phase normalisation: n = 24 gives +0.5032, n = 25 gives +0.5242.
  - Bessel, magnitude normalisation: n = 25 gives +0.5191 (n = 24 gives +0.4983, inside).
  - Bessel, delay normalisation: stays inside at a 10 Hz cutoff (n = 25: +0.3218).
  - Upper skirt of a Butterworth band-pass 5 … 10 Hz: prototype order 24 gives +0.5176, order 32 gives +0.6902.
  - `check_probes.py rolloff` on the verifier's probe data: 684 comparisons, 25 outside, as the report says.
- **Why it is not refuted.**
  - The statement covers every order and every octave that ends at or below f_s/32. One accepted order in one such octave breaks it.
  - The project's test does not reach the failing orders: `RollOffTests.swift:22-25` uses orders 2–16, and `:98-113` uses an octave that ends at 1 280 Hz.
  - The acceptance therefore fails, which is blocking.
- **The cure is a change to the document.** FIX-4 applies: file a change request and pause the package. `IIRDesign.swift:89-92` repeats the bound and has to follow that change request.

### A-2: a representable gain is lost in the bilinear transform

- **Rule.** §11.6, "a result is wrong". The reports cite §11.4, which is the section "Two independent verifiers". No change request covers this.
- **Reproduction** (`repro-audit1`).
  - Butterworth and Chebyshev I 1 dB low-pass, order 512, 10 kHz at 48 kHz: gain 0, and ‖H‖ = 0 in ZPK and in sections, with no error.
  - The direct `bilinear(sampleRate: 2)` of the analog system also gives gain 0.
- **Exact gains** (`audit_numbers.py`).

  | Design | Analog gain | Digital gain | Running ratio alone | Representable? |
  |---|---|---|---|---|
  | Butterworth | 10^249.365 | 10^−161.575 | 10^−410.940 | Both gains yes; the ratio is below the smallest subnormal (10^−323.306) |
  | Chebyshev I 1 dB | 10^95.832 | 10^−239.904 | 10^−335.736 | Both gains yes; the ratio is below the smallest subnormal |

  - SciPy 1.15.3's `bilinear_zpk` and `iirfilter(…, output='zpk')` return NaN here, so the golden vectors cannot catch the loss. I confirmed that NaN.
- **Beyond the finding** (`audit-1`). The loss starts well before the gain reaches 0. Butterworth at 10 kHz / 48 kHz, relative error of |H(0)|:

  | Order | Gain | Relative error of \|H(0)\| |
  |---|---|---|
  | 390 | 8.4·10⁻¹²⁴ | 4.6·10⁻¹² |
  | 395 | 2.2·10⁻¹²⁵ | 2.4·10⁻⁷ |
  | 400 | 5.9·10⁻¹²⁷ | 1.8·10⁻³ |
  | 405 and above | 0 | 1 |

  - At order 400 the gain is normal but wrong: the ratio went subnormal before it met the gain.
  - So from about order 391 to 404 the design comes back with a gain that is not zero, and silently inaccurate.
- **Code.**
  - `Bilinear.swift:52-58` forms Π(2f_s − z)/Π(2f_s − p) as a running product and multiplies by the gain only at the end.
  - The guard at `:59` tests `isFinite` only.
- **Verdict.** Confirmed, blocking.

### A-3: a gain that underflows comes back as a zero filter

- **Rule.** §11.6, "a result is wrong" (the reports cite §11.4). No change request covers this.
- **Reproduction** (`repro-audit1`: `a3DirectTheTransformationsRefuseAGainThatUnderflows`, `a3AnUnrepresentableGainIsATypedErrorNotAZeroFilter`). Each of these five calls returns gain 0 and ‖H‖ = 0, with no error:

  | Package | Call | Exact gain |
  |---|---|---|
  | WP-412 | Low-pass transformation of the order-128 prototype at 0.001 | 10^−384 |
  | WP-413 | Band-pass transformation of the same prototype, bandwidth 0.001 | 10^−384 |
  | WP-414 | Bilinear transform of order 512 at 0.4 rad/s | Analog 10^−203.745 (representable); digital 10^−526.140 (not) |
  | WP-418b | `IIRDesign`, Butterworth order 256 at 100 Hz / 48 kHz | Analog 10^−404.998 (already underflows); digital 10^−559.589 |
  | WP-418a | Analog design, order 128 at 0.001 rad/s | 10^−384 |

  - The control, cutoff 1 000 (gain 10^384), throws `invalidParameter`.
- **What stands.**
  - A filter whose exact response at DC is 1 comes back with ‖H‖ ≡ 0 and no error. That is a wrong result.
  - The package's own answer to a gain it cannot represent is a typed error: see the overflow guard (`FrequencyTransformation.swift:83-84`, "…or its gain out of range") and the prototype (`AnalogPrototype.swift:226-231`).
  - This part is blocking.
- **What does not stand as blocking: the subnormal sub-case.**
  - The case is Chebyshev I 1 dB, order 128, at 100 Hz. I reproduced it exactly (`audit-1`): gain 3.13706·10⁻³¹⁸; ‖H(0)‖ is off by 7.31·10⁻⁸ relative in ZPK and by 7.42·10⁻⁸ in sections.
  - The exact gain is 10^−317.503. A double holds that value with about 19.3 significant bits, a relative step of 1.6·10⁻⁶, and the package returns that correctly rounded double.
  - The report compares the error with 10⁻⁹. That is the STG-2 golden tolerance for orders 1, 2, 5 and 8 (`SPEC:1844`), not for order 128.
  - So this is a precision limit of a single double gain: non-blocking. The cure for A-2 would remove it too: compute the gain with its exponent kept apart, and spread it over the sections.
- **The typed error is not a documented contract.** The finding infers it from the guard's message and from what the prototype does; there is no `Throws` clause. The finding does not need it, because it stands on "a result is wrong".
- **Verdict.** Confirmed in part, blocking.

### A-4: κ is infinite for a multiple root

- **Rule.** NUM-1 (`SPEC:1005`): "No NaN, no infinity. Every division states its result for a zero or sub-floor denominator".
  - κ(r) = Σ‖aₖ‖·‖r‖ᵏ / (‖r‖·‖p′(r)‖) divides by p′(r), which is 0 at a multiple root.
  - No change request exempts κ. I checked CR-001 … CR-025.
- **Reproduction** (`repro-audit1`, `a4ConditionNumbersAreFinite`). κ is inf in each of these cases:
  - the double root of x² − 2x + 1;
  - an overflowing weighted sum;
  - `rootConditions(of: x² − x + 1/4)`, which gives [inf, inf];
  - `TransferFunction([1], [1, −1, 0.25]).poleConditions`, which gives [inf, inf].
- **Beyond the finding** (`audit-1`). `analysis(sampleRate:)` of the same system reports `rootConditions.poles` = [inf, inf] and `largest` = inf.
- **Code.**
  - `PolynomialRootFinder.swift:59` does `return .infinity`.
  - The infinity is documented at `:28-29`, `:40-42` and in `SystemAnalysis.swift:27`.
  - `PolynomialRootFinderTests.swift:225-236` pins it.
  - Elsewhere the package states a finite result for the same situation: `greatestFiniteMagnitude` in `EllipticFunctions.swift:49-52` and `LTISystem.swift:62` and `:203`.
- **Why it is not refuted.** A documented infinity is still an infinity, and NUM-1 asks for a stated, finite result.
- **Verdict.** Confirmed, blocking.

## 2 Gaps in the verification (duty 2)

| Package | Gap |
|---|---|
| WP-419 | **FIX-4 was not carried out.** The report says: "None filed by the verifier. A-1 needs one: the statement of §6.3.4 is a property of the bilinear transform that no implementation can meet at every order." FIX-4 makes filing that change request the verifier's job, and the package is then paused. Instead it is left `blocking`, for a fix cycle (FIX-1) that cannot converge. No change request about §6.3.4 exists in `Docs/Process/changes/`, nor in main. |
| WP-403, WP-428a | **The non-blocking rating of A-NB3 is not argued.** The verifier's own probe shows the public API returning NaN: `SecondOrderSections` with a NaN coefficient gives poles [nan, nan] and `stabilityMargin` nan (`VerifierA/out/edges.json`, "sos with a NaN coefficient"). Yet A-4 rates an infinity under the same rule, NUM-1, as blocking. The package also answers the same input with a typed error in `TransferFunction.poles` and in ZPK → sections. If NUM-1 reaches values that a caller supplies, A-NB3 is blocking. If it does not, the report has to say why, for example through NUM-1's sentence on the source adapter. The report does neither. I read these values from the verifier's probe output and did not run the case myself. |
| WP-404, 408, 409, 412, 413, 418a, 418b, 419, 421, 430 | **The lens-N edge case "non-finite input (NUM-1)" (`SPEC:1796`) is not shown.** No cited test feeds a NaN or an infinity, and no probe result for one is cited. Material exists but is not cited:<br>• The project's tests feed NaN or infinity for WP-409 (`invalidRipplesAndAttenuationsAreTypedErrors`, which covers elliptic), WP-412 and 413 (`invalidTransformationsAreTypedErrors`), WP-418a and 418b (the `failure` cases of `IIRDesignTests.swift`), and WP-421 (the `failure` cases of `EqualizerTests.swift`).<br>• The verifier's probe ran ZPK → sections with a NaN zero (WP-404: typed error), a transformation with a NaN zero (WP-412 and 413: typed error), and group delay with NaN coefficients (WP-430: `nil`).<br>• For WP-408 (the parameter m) and WP-419 (a NaN or infinite roll-off, which `RollOff.swift:84` guards), neither the tests nor the probe feed a non-finite value.<br>I did not run these cases. Not applicable: WP-405, 410 and 411, whose inputs are integer orders. Shown: WP-401, 402, 403, 406, 407, 414, 415, 416, 417, 420, 428a, 429. |
| WP-404 | **No edge case is shown at all.** Apart from the definition "an odd order gets one first-order section", the report shows no edge case run for the pairing: no system without roots, no unpaired real roots, no system with more poles than zeros, and no non-finite input. The probe's NaN-zero case is not cited. |
| WP-404, 405, 406, 407, 408, 409, 412, 413, 414, 415, 416, 417, 418a, 418b, 419, 421, 428a, 429 | **The precision choice, a lens-N item, is not stated.** These reports repeat the duty in the lens line but say nothing about it for the package. This is a gap of record only, since §6.1 makes design maths double. The choice is stated in WP-401, 402, 403, 410, 411 (double-double, through mutation M8), 420 and 430. |

### Checked and not gaps

- **The reports exist and are complete.**
  - All 25 reports exist. Each lists its acceptance checks, how they were run and what they gave.
  - The figures trace to the verifier's logs: Debug and Release 332 of 332, Debug with 3 iterations, golden check "197 files of 27 generators", the recompute (for example `iir_design` 1 242 comparisons, `iir_order` 480 with no deviation), the probes, the reproductions, and mutations M1 … M11.
  - I read these logs but did not rerun the whole target, the mutations or the golden check.
- **The 13 ALG rows** (WP-402, 404–411, 414, 418a, 418b, 421).
  - Each report checks the currency record: the note's first lines, then row 3, 4, 12 or 20 of `currency-2026-11.md`, dated 2026-11-15, which names what was consulted.
  - Each checks the stability note against the code with a mutation that makes its named tests fail and is then restored byte-identical. The log ends "FINAL: Sources pristine".
  - A-NB8 reports that rows 3 and 4 searched other subjects. That still meets the lens duty of §7.3 (the record exists, is dated and names what was consulted).
- **No tolerance was loosened.** The golden tolerances in the tests equal STG-2.
  - The looser figures in the tests do not guard an acceptance: 10⁻⁶ and 10⁻⁵ for numeric group-delay derivatives, 10⁻² for the Wilkinson κ, and 10⁻⁶ for a pre-warp approximation.
- **WP-402: the LAPACK failure is a typed error, and the test exercises it.** `aLAPACKFailureIsATypedError` puts a NaN in the matrix, so `dhseqr` fails with info > 0.
- **WP-430.** The STG-2 golden for WP-430 is the group delay. The impulse and step responses are compared with `sosfilt` (2.8·10⁻⁷ and 9.9·10⁻⁷ of the peak, against WP-208's 10⁻⁵).
- **WP-428a.** The infinity of A-4 also reaches `SystemAnalysis.rootConditions`. That is a numerical figure of §6.3.8, which belongs to WP-428b and is not in this batch. A-4 names that location.
- **A-NB7 (WP-429) is argued.** It is a response near a pole on the unit circle at ω = 10⁻⁹, evaluated from coefficients.

## 3 Spot checks

I chose the thinnest pass verdicts:

- WP-415, 416 and 417 share their probe and recompute counts.
- WP-420 is among the shortest reports.
- WP-428a's fixture row reports "Passed" with no figure.

I ran each package's acceptance suite together with checks of my own (`VerifierA/audit/run-spot.sh 1`, which runs `AuditM4aASpot`, `FilterOrderTests`, `CookbookEqualizerTests` and `LTISystemRootsTests`). 28 tests in 4 suites passed, and every acceptance test the reports cite for these packages was among them. Afterwards the tree was identical to `.build/pristine`. `audit_spot.py` compared the printed values with the oracles.

| Package | My cases | Oracle | Result | Agrees with the pass verdict |
|---|---|---|---|---|
| WP-415, 416, 417 | 12 schemes of my own (three each of low-pass, high-pass, band-pass and band-stop) × 4 families × {44.1 kHz, 96 kHz, analog} = 144 | SciPy `buttord`, `cheb1ord`, `cheb2ord`, `ellipord` | Order equal in 144 of 144. Natural frequency within 1.45·10⁻¹⁵ relative (bound 10⁻⁹). `FilterOrderTests`: 14 passed | yes |
| WP-420 | 54 peaking sections (2 rates × centres 50, 3 300, 15 000 Hz × gains 3, −9, 18 dB × Q 0.7, 2, 8)<br>108 shelving sections (low and high × midpoints 80, 2 500, 12 000 Hz × gains 6, −4.5, 15 dB × slope 1, slope 0.5, Q 0.9 × 2 rates) | The Audio EQ Cookbook formulas, written out in `audit_spot.py` | All 162 accepted.<br>• Coefficients within 5.33·10⁻¹⁵ (bound 10⁻¹²).<br>• Peaking gain at the centre within 1.68·10⁻¹¹ dB (bound 0.01 dB).<br>• Shelf at its midpoint within 4.75·10⁻¹¹ dB of half the gain.<br>• Shelf gain at 0 Hz or Nyquist within 2.41·10⁻¹⁰ dB.<br>• No section accepted with its upper half-gain point at or beyond 0.49·f_s.<br>`CookbookEqualizerTests`: 4 passed | yes |
| WP-428a | An analog system given as coefficients, 3(s + 1)(s² + 4) / ((s + 2)(s² + 0.2s + 1))<br>Digital sections [1, 0, −1 \| −1, 1] and [2, −1, 0 \| 1, 0], with poles at e^{±jπ/3} and −1, on the unit circle | `numpy.roots` and the closed forms | Analog: zeros within 2.2·10⁻¹⁶, poles within 3.9·10⁻¹⁶; gain 3; stable; margin 0.1.<br>Digital: zeros exact, poles within 1.1·10⁻¹⁶; gain 2; not stable; margin 0; largest pole radius exactly 1. The ZPK form has gain 2, with 3 zeros and 3 poles once the pair at the origin cancels.<br>`LTISystemRootsTests`: 7 passed | yes |

## 4 How this was run

Everything runs from ROOT. None of it is part of the package: each Swift file is copied into the test target for one run and then removed.

| What | Command | Output |
|---|---|---|
| The verifier's reproductions, rerun | `VerifierA/scripts/run-repro.sh audit1` | 6 tests fail as the findings say; the 2 controls and `wp430…` pass |
| My probes of A-1 … A-4 | `VerifierA/audit/run-audit.sh 1` (copies `AuditM4aATests.swift`, suite `AuditM4aA`) | All 4 tests fail where the findings hold |
| My spot checks | `VerifierA/audit/run-spot.sh 1`, then `python3 -I VerifierA/audit/audit_spot.py <log>` | 28 passed |
| Closed forms for A-1 … A-3, and SciPy's NaN | `python3 -I VerifierA/audit/audit_numbers.py` | — |
| The verifier's roll-off probe data | `python3 -I VerifierA/scripts/check_probes.py rolloff` | — |

The key lines of each run are kept in `VerifierA/audit/out/`, because the logs in `.build/` are deleted at the end of this audit:

- `repro-audit1.lines.txt`
- `audit-1.lines.txt`
- `spot-1.lines.txt`, which `audit_spot.py` also accepts as input
- `audit_numbers.txt`
- `audit_spot.txt`

**Remarks.**

- The citation "§11.4" in A-2 and A-3 should read §11.6. The severity does not change.
- Main has moved on since the snapshot, but none of the changes bear on these findings:
  - CR-024 and CR-025 cover the engine and extensions, and CR-015 item 5 is amended by CR-024.
  - Main adds one design test file, `CoverageDoubleDoubleTests.swift`.
  - The engine and pipeline sources of `ZTronDSPCore` changed. `ZTronDSPDesign` and the specification are unchanged.
