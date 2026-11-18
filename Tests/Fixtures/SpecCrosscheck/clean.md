# Fixture specification — clean

- Work packages were re-split; there are 7, in 6 rows.

## 2. Requirements traceability

| Req | Requirement | Specified in | Delivered by |
|---|---|---|---|
| R-01 | First | §1 | WP-001…003, WP-102a |
| R-02 | Second | §1 | WP-905 and every `ALG` package |

## 12. Work packages

`OPT` triggers. WP-102b: the owner's request.

| Milestone | Packages | Exit criterion |
|---|---|---|
| M0 Foundation | WP-001…003 | It builds. |
| M1 Values | WP-102a…102b | It runs. |
| M9 Hardening | WP-905a…b | It ships. |

- In M0, WP-003 waits for the values (WP-102a).

### M0 — Foundation

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-001 | Manifest with a `|` in code | — | Builds | A, T | |
| WP-002 | Lint | 001 | Reports | A, T | |
| WP-003 | Gate | 001–002, 102a | Exit codes | T, A | ALG |

### M1 — Values

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-102a | Units | 001 | Round trips | N, A | |
| WP-102b | More units | 102a | Round trips | N, R | OPT |

### M9 — Hardening

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-905a…b | Audit | all | Signed off | N, A | |

## 13. Risks

A split is named like `WP-002a`, `WP-002b`.
