# Unchecked Sendable register

| Type | File | Threading contract |
|---|---|---|
| HeatmapFeed | Sources/ZTronDSPCore/Feeds/HeatmapFeed.swift | Single writer on the analysis thread, readers on any thread through the sequence lock |
