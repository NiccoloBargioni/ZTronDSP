# Fixture specification — one defect of every class

- Work packages were re-split; there are 9, in 8 rows.

## 2. Requirements traceability

| Req | Requirement | Specified in | Delivered by |
|---|---|---|---|
| R-01 | First | §1 | WP-001…003, WP-777 |
| R-03 | Out of order | §1 | WP-001 |

## 12. Work packages

`OPT` triggers. WP-001: never.

| Milestone | Packages | Exit criterion |
|---|---|---|
| M0 Foundation | WP-001…009 | It builds. |
| M1 Values | WP-101…102 | It runs. |

### M0 — Foundation

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-001 | Manifest | 004 | Builds | A, T | |
| WP-002 | Lint | 001, 555 | Reports | A, A | |
| WP-003 | Gate | 101 | Exit codes | T, X | BOGUS |
| WP-003 | Gate again | — | Exit codes | T, A | |
| WP-004 | Cycle | 001 | Loops | N | OPT |
| WP-0x5 | Malformed | — | Nothing | A, T | |
| WP-006 | Too few cells | — | A, T | |

### M1 — Values

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-101 | Units | 001–444 | Round trips | N, A | |
| WP-102 | Words | soon | Round trips | N, A | |

## 13. Risks

Nothing delivers WP-888, and WP-001…999 is not a range.
