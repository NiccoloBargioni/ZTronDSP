# Stability note — row n, operation

File as `Docs/Numerics/<row>.md`, one per row of the algorithm register (§7.2) and of its twin
in the stability register (§7.5). Every `ALG` package delivers or extends one (NUMS-2); lens N
verifies it against the code.

| Field | Value |
|---|---|
| Register row | Number and operation, as in §7.2 |
| Selected algorithm | As registered |
| Packages | WP-nnn, … |
| Precision | Float32 on the signal path, Double for design, or how it is chosen at run time (NUMS-3) |

## Currency check (§7.3)

At most five minutes, at the start of the package.

| Field | Value |
|---|---|
| Date | YYYY-MM-DD |
| Registered source confirmed | Yes or no, and which |
| Consulted | DAFx, ISMIR, ICASSP, JAES, IEEE/ACM TASLP, ACM TOMS, Apple's Accelerate and Metal release notes: which of them, and what was searched |
| Outcome | Still current, or the superseding method and the change request raised for it (never adopted silently) |

## Hazard

## Bound or measured behaviour

The bound, or the measurement with the fixture that shows it.

## Mitigation

What the code does about the hazard, and where.

## Stress test

The test, the fixture it draws from the stress-fixture library (WP-016), and the evidence that
it fails when the mitigation is removed.
