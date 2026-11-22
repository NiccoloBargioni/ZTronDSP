# Register audit of the fixture

| # | Operation | Packages | Notes | Currency | Notes against the code | Stress tests | Mutations | Precision | Open |
|---|---|---|---|---|---|---|---|---|---|
| 1 | Real FFT | WP-001 | `one.md` | 2026-11-21: current | true; `Sources/Thing.swift` | `Tests/ThingTests.swift`: `works` | M1 killed | Float32 | none |
| 2 | Framing | WP-002 | `two.md` | not searched on 2026-11-21 | true | `Tests/ThingTests.swift`: `ThingTests.alsoWorks` | M2 killed | none in arithmetic | none |
| 3 | IIR filtering | WP-004 | `three.md`, `one.md` | 2026-11-21: current | corrected | `Tests/ThingTests.swift`: `works`, `alsoWorks` | M3 killed | Float32, Double | open: A-1 |

**Supplementary notes.** `extra.md`: a note no row of the fixture owns.
