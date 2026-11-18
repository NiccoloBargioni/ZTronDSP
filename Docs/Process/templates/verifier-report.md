# Verifier report — WP-nnn, lens ?

File as `Docs/Process/reports/WP-nnn-A.md` or `WP-nnn-B.md` (§11.9).

| Field | Value |
|---|---|
| Package | WP-nnn — title |
| Lens | One of N R A T V S, as listed for the package in §12 (VER-1) |
| Verifier | A or B, and who; not the implementer, not the other verifier, not the integrator (§11.1) |
| Revision reviewed | |
| Fix cycle | 0 for the first verification, then 1 to 3 (FIX-3) |
| Verdict | `pass` or `blocking` (VER-4) |

## What was received (VER-2)

- [ ] The brief
- [ ] The specification sections it cites
- [ ] The revision under review, as a checkout that can be run and modified
- [ ] The test, lint and coverage output
- [ ] Nothing of the other verifier's findings, and nothing of the implementer's reasoning, before this report was filed

## Acceptance checks run by the verifier (VER-3)

A statement in the implementer's notes is not evidence. Each check of the package's row in §12:

| Check | How it was run | Result |
|---|---|---|

## Lens checklist (§11.5)

Keep the block of this report's lens.

- **N — numerical correctness.** Result matches the cited definition and the golden vectors within the stated tolerance. Edge cases: empty, length 1, DC, Nyquist, silence, full scale, non-finite input (NUM-1). Precision choice. `ALG`: the currency record and the stability note, checked against the code. No tolerance loosened to make a test pass.
- **R — real-time safety and performance.** RT-1…RT-9. The allocation audit exists and passes. No hidden copies. Complexity as registered in §7.2. A benchmark is recorded. Setups created when the plan is compiled only. Implementations bound by size (SEL-3).
- **A — API, architecture, platform.** Names and shapes per §4–§8. Strategy and Decorator conformance. DEP, EXT and VIS rules. Immutability and no configuration objects (IMM, API-6). Sendable, concurrency and background rules (§9.2). Availability (PLAT-1). UIKit boundary (§8.6). Approval-gated API (§9.5). Typed errors. Public API documented with its threading contract.
- **T — tests and coverage.** Every acceptance check exists as a test and fails when the implementation is broken; the line changed to confirm it: ______. COV-3. Tests are seeded and deterministic and do not synchronise with sleeps. Negative paths are covered.
- **V — visual stability and rendering.** V-rules. Dirty-set causes. Draw and upload counters asserted. No per-frame SwiftUI invalidation. Animation, pinch and size-transition rules (§8.7–8.9). Golden images changed only with justification.
- **S — system integration.** CAP and MIC rules. Session ownership. The tables of §4.5 and §4.6. Permission paths. Idempotent start, stop and detach. Behaviour when hardware is absent or changes.

## Findings (VER-4)

Blocking: a numbered rule or an acceptance statement of §4–§10 is violated; an acceptance check
of §12 is missing, failing, or does not exercise the code; a result is wrong; coverage is below
COV-3; public API differs from §4–§8 or Appendix A without a change request. Everything else is
non-blocking and goes to the ledger backlog with an owner (§11.6).

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|

## Re-verification (FIX-1), from fix cycle 1 on

| Finding | Raised by this lens? | Fix confirmed, or "nothing broken in this lens's domain" | Evidence |
|---|---|---|---|

## Change requests filed (FIX-4)

A defect or ambiguity of the specification is a change request; the package is paused, not bent to fit.
