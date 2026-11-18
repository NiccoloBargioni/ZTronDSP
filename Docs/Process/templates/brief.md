# Brief — WP-nnn

The integrator writes this from the package's row in §12 before the package becomes ready
(WP-R3). The implementer must not need anything else.

| Field | Value |
|---|---|
| Package | WP-nnn — title, as in §12 |
| Milestone | M? |
| Goal | The "Package" cell of §12, unchanged |
| Dependencies | The "Dep" cell of §12; all of them are `Done` (WP-R4) |
| Lenses | Two of N R A T V S, as in §12 |
| Tag | none, `ALG` or `OPT` |
| Target | The one target the package delivers into (WP-R2) |

## Acceptance

The "Acceptance" cell of §12, unchanged, one check per line. For a package that delivers a
stage, a step or a recipe, the checks of STG-1 are added; for a "Golden" acceptance, STG-2 and
the oracle, grid and tolerance of its row in §12's table.

## Specification sections to read

## Files to create or change

## Out of scope

## Rules of the time box

- 30 minutes of implementation (WP-R1). No path to done at minute 20: stop and ask for a split (§11.7).
- About 150 lines of production code, one new public type or three public functions, tests in the same package (WP-R2).
- `ALG` only: begin with the currency check of §7.3 (five minutes at most) and end with the stability note `Docs/Numerics/<row>.md` (NUMS-2).
- `OPT` only: the trigger that occurred, and where it is recorded.
