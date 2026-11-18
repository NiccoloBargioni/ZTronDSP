# Compile fixtures

Files that `Scripts/compile-fixtures.sh` type-checks one by one, as a client of the package
would write them (§10.1, the order rules of §5.8).

- `valid/` — every file must compile.
- `invalid/` — every file must fail to compile, and the compiler's output must contain each
  sentence the file names in a header line `// expect: <sentence>` (ORD-4).

A fixture imports the products (`ZTronDSP`, `ZTronDSPUI`, `ZTronDSPTesting`), holds one idea,
and is named after the rule it shows (`O-05-DecibelsBeforeMelScale.swift`). It sees no
`package` or internal symbol. `// flags: …` adds compiler flags for that file.

The fixtures of the harness's own self-test are elsewhere, in `Tests/Fixtures/CompileFixtures`.
