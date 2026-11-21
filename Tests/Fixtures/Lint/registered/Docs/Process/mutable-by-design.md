# Mutable by design

| Symbol | File | Reason |
|---|---|---|
| `HeatmapFeed.history` | `Sources/ZTronDSPCore/Feeds/HeatmapFeed.swift` | Trimmed under memory pressure (MEM-1) |
| `Ramp.current` | `Sources/ZTronDSPCore/Toolkit/Ramp.swift` | Set by the module where the type cannot be (a fixture) |
| `Ramp.Phase.radians` | `Sources/ZTronDSPCore/Toolkit/Ramp.swift` | As `Ramp.current`, on a nested type (a fixture) |
