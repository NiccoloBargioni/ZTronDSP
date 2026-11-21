# ``DocFixture``

The catalog of the documentation fixture (Scripts/tests/test-docs.sh): its one example is the
region `levels` of `Clean.swift`, compiled with the fixture.

<!-- snippet: Tests/Fixtures/Docs/Clean/Clean.swift#levels -->
```swift
let quiet = Level(decibels: -40)
return quiet.raised(by: 6)
```

A block that is not Swift needs no region:

```text
-34 dB
```
