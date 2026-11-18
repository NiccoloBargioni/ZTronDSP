# Verifier report — WP-110a, lens A

| Field | Value |
|---|---|
| Package | WP-110a — Signal domains, `SampledSequence`, the sink-capability protocols, run-time `DomainTag` |
| Lens | A |
| Verifier | A (agent); not the implementer, not the other verifier, not the integrator |
| Revision reviewed | main tree snapshot 2026-11-16 04:05, after CR-022 (the files of these packages have not changed since) |
| Fix cycle | 0 |
| Verdict | `blocking` |

## What was received (VER-2)

- [x] The brief (`briefs/21-verifier-a-m1.md`)
- [x] The specification sections it cites
- [x] The revision under review, as a checkout that can be run and modified: `Domains/SignalDomain.swift` is byte-identical with the main tree. `StorageAndDomainTests.swift` differs from the main tree's copy (16 Nov 04:39) by one trait on a WP-105 test only; the `SignalDomainTests` suite is the same. Of the files the run-time check of A-21 passes through, `Compiler/PlanCompiler.swift` and `Pipeline/Structure.swift` differ from the main tree's copies (16 Nov 04:08 and 04:17, after the snapshot: a fused skeleton, and one renamed protocol at `Structure.swift:217`); the lines that refuse the custom domain (`PlanCompiler.swift:178`, `:193` here, `:179`, `:194` there; `DomainRule.swift:38`; `Structure.swift:227`, `:244`, `:253`) read the same, so A-21 holds for the main tree
- [ ] The test, lint and coverage output: not handed over; tests and gates were run by the verifier, coverage was not measured (lens T)
- [x] Nothing of the other verifier's findings, and nothing of the implementer's reasoning beyond what the tree holds (see `VerifierA/README.md` for its disclosures)

## Acceptance checks run by the verifier (VER-3)

Runs (simulator `ztdsp-27-vm1a`, iOS 27.0; logs in `.build/logs/`; scripts in `VerifierA/`, see its README):

- **[D]** `VerifierA/run-m1.sh a2-debug-1 test`: the 25 M1 suites, Debug, 142 tests, all pass. **[D3]** `ZTD_XCARGS="-test-iterations 3" VerifierA/run-m1.sh a2-debug-x3 test` after every seeded change was restored: Debug, 142 tests × 3 repetitions, all pass (27.6 s); this is the build left in `.build/xcode`.
- **[R]** `ZTD_CONFIG=Release VerifierA/run-m1.sh a2-release-1 test`: Release, 142 tests, all pass.
- **[P]** `VerifierA/run-probes.sh` (Debug, and `ZTD_CONFIG=Release`): suite `VerifierA_WP110a` (`VerifierA/Tests/VerifierAProbesArchitecture.swift`), with two domains written in the test target, outside `ZTronDSPCore`: `VerifierALoudness: RealVectorDomain` and `VerifierAControl: SampledSequence, ScalarValuedDomain`, each tagged `.custom(…)`, and a step producing each. `confirmTheTablesOfSection52` passes; `findingTheTagOfACustomDomainCannotSayWhatItsTypeSays` (3 issues) and `findingAPipelineOverACustomDomainCompilesAndIsRefusedWhenItRuns` (2 issues) fail, in Debug and in Release.
- **[G]** `Scripts/lint-bans.sh`: clean (parts 1–4, 448 files). `Scripts/api-digest.sh --check`: 10 digests equal the built modules. `Scripts/check-dependency-graph.sh`: the graph equals §4.2.
- **[C]** `VerifierA/doc-coverage.sh` on the Debug build (`.build/logs/a2-doc-coverage.txt`).

| Check | How it was run | Result |
|---|---|---|
| Tags are distinct | tree `SignalDomainTests` (`StorageAndDomainTests.swift:204–282`) [D][R]; [P] the 21 stock domains (samples, twelve spectra of three axes by four value kinds, quefrency, mel cepstrum, chroma, lags, tempo spectrum, envelope, novelty, scalar): 21 distinct tags and 21 distinct descriptions | pass |
| Conformances equal the tables of §5.2 | tree `SignalDomainTests` [D][R]; [P] `confirmTheTablesOfSection52`: for every stock domain, the protocols it conforms to (sampled sequence, real vector, scalar valued), the same three answers from its tag, and the frame kind it is delivered as, against the rows of §5.2 | pass for the stock domains |
| The two tiers agree (ORD-2) for a domain the package invites from outside (`DomainTag.custom`, "a domain defined outside the package, by name") | [P] `findingTheTagOfACustomDomainCannotSayWhatItsTypeSays`, `findingAPipelineOverACustomDomainCompilesAndIsRefusedWhenItRuns` | `Pipeline { VerifierALoudnessStep() }.emit(to: HeatmapFeed(history: 16))` compiles and then throws "Emit cannot follow a signal of the domain VerifierALoudness (at Emit[1])"; `Pipeline { VerifierAControlStep() }.testGain(0.5)` compiles and then throws "TestGain cannot follow a signal of the domain VerifierAControl (at TestGain[1])". Without a sink, the custom step runs. **fail** (A-21) |

## Lens checklist (§11.5)

- **A — API, architecture, platform.** Names and shapes per §4–§8. Strategy and Decorator conformance. DEP, EXT and VIS rules. Immutability and no configuration objects (IMM, API-6). Sendable, concurrency and background rules (§9.2). Availability (PLAT-1). UIKit boundary (§8.6). Approval-gated API (§9.5). Typed errors. Public API documented with its threading contract.

- Names and shapes per §5.2: `SignalDomain` with `tag`, `SampledSequence`, `RealVectorDomain`, `ScalarValuedDomain`, the spectral axes and values, the ten domain types and `DomainTag` with its `Axis`, `Values` and `FrameKind` (`SignalDomain.swift:7–121`). The digest is unchanged [G]. Domains are uninhabited enums, so nothing here holds state; everything is `Sendable`.
- EXT: the protocols are public and `DomainTag.custom(String)` (`:103–104`) is documented for "a domain defined outside the package"; CR-009 likewise gives `FeedAxis.indices(count:)` the reason "A domain defined outside the package needs the same". A domain so defined is accepted by tier 1 and refused by tier 2 (A-21).
- VIS-2: no threading contract anywhere in the file (A-22).
- No configuration object, no Combine, `AnyView` or UIKit; availability is not raised.

## Findings (VER-4)

| # | Checklist item | Location | Evidence | Severity |
|---|---|---|---|---|
| A-21 | ORD-2: "Tier 1 and tier 2 MUST agree … acceptance by the compiler must coincide with acceptance by the rule"; EXT-1 (a user's domain has what a stock one has) | `Sources/ZTronDSPCore/Domains/SignalDomain.swift:124–143`, `:151–160` | The run-time tag of a custom domain answers `false` to `isSampledSequence`, `isRealVector` and `isScalarValued` whatever protocols its type adopts (`:126`, `:136`, `:142`), so every rule built on them refuses it: `DomainRule.sequence` (`DomainRule.swift:38`, which every `SequenceStage` gets), the heat map and the two bindings (`Structure.swift:227`, `:244`, `:253`). The type checker accepts the same compositions because the type adopts `RealVectorDomain` or `SampledSequence` (figures above). By reading only (not run): `frameKind` is `.real` for every custom domain (`:151`, `:156`), also for a custom `ScalarValuedDomain` whose step emits scalar frames. Reproduce: [P] `VerifierA_WP110a/findingAPipelineOverACustomDomainCompilesAndIsRefusedWhenItRuns()` and `findingTheTagOfACustomDomainCannotSayWhatItsTypeSays()`. Resolve: let a custom tag carry what its type declares (for example `.custom(name, sampledSequence:realVector:scalarValued:frameKind:)` filled in from the protocols), or derive the tier-2 answers from the type; or a change request that restricts what a custom domain may adopt, with fixtures. | blocking |
| A-22 | VIS-2: "Every public symbol is documented with its threading contract: which context may call it, and whether it may allocate" | `Sources/ZTronDSPCore/Domains/SignalDomain.swift` | No declaration of the file states which context may use it or whether it allocates; `description` builds a `String` (`:162–190`). 19 of its 78 public symbols have no documentation comment at all: the ten `DomainTag` cases other than `.custom` (`:93–102`), `DomainTag.Axis` and its three cases (`:106`), `DomainTag.Values` and its four cases (`:107`). Reproduce: [C], and `grep -n -i -E 'thread\|context\|allocat' Sources/ZTronDSPCore/Domains/SignalDomain.swift` (no line). Resolve: one sentence on the protocols and on `DomainTag` (usable from any context, allocation-free except `description`), and comments on the cases. | blocking |

## Re-verification (FIX-1), from fix cycle 1 on

Not applicable: fix cycle 0.

## Change requests filed (FIX-4)

None. If the owner decides that a custom domain may not be a sampled sequence, a real vector or scalar valued, A-21 is resolved instead by a change request saying so, with must-not-compile fixtures that enforce it at tier 1.
