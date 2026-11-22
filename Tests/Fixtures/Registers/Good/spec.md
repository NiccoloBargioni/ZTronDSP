# A specification for the self-test of Scripts/check-registers.sh

## 7. Acceleration policy

### 7.2 Algorithm register

| # | Operation | Selected algorithm | Cost | Registered alternatives | Source |
|---|---|---|---|---|---|
| 1 | Real FFT | A transform | O(N log N) | — | A library |
| 2 | Framing | A ring | No copy | Copy on wrap | — |
| 3 | IIR filtering | Biquads | O(sections) | — | A book |

### 7.3 Currency gate

Text.

### 7.5 Numerical stability register

| # | Operation | Hazard | Bound or measured behaviour | Mitigation | Shown by |
|---|---|---|---|---|---|
| 1 | Real FFT | Round-off | A floor | Floors | WP-001 |
| 2 | Framing | None | Exact | Counters | WP-002 |
| 3 | IIR filtering | Poles near 1 | A figure | Precision | WP-004 |

---

## 12. Work packages

### M0 — Foundation

| ID | Package | Dep | Acceptance | Lenses | Tag |
|---|---|---|---|---|---|
| WP-001 | A transform | — | It works | N, R | ALG |
| WP-002 | A ring | — | It works | R, T | ALG |
| WP-003 | Not an algorithm | — | It works | N, A |  |
| WP-004 | A biquad | 001 | It works | N, R | ALG |
