# Unchecked Sendable register of the external package (§9.2)

`@unchecked Sendable` is allowed only on types whose threading contract is written at the
declaration. The rule of the main package holds here too: each such type under `Sources/` is
listed, and `Scripts/external-parity.sh --step rules` keeps this register equal to the code
with the main package's own lint (`Scripts/lib/lint_bans.py`, part 4).

`Type` is the type as the lint reports it. `File` is its path under this package's root.

| Type | File | Threading contract |
|---|---|---|
| `PeakHoldMeter` | `Sources/ExtensionGuide/Nodes/PeakHoldMeter.swift` | The state is three atomic words. `write` (analysis thread) is the only writer of the newest value and of the mark; `resetPeak()` (any thread) stores a request word that the writer takes with an exchange; `claim` (control context) stores while no writer runs. Readers load single words. |
| `ClickSource` | `Sources/ExtensionGuide/Kernels/ClickSource.swift` | Everything but `position` is immutable. `position` is advanced by `render` on the thread the engine paces the source on and reset by `prepare` on the control context while the source does not render. |
