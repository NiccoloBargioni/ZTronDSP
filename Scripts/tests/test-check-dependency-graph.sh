#!/bin/bash
# Self-test of Scripts/check-dependency-graph.sh (WP-001).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
FIXTURES="$ROOT/Tests/Fixtures/DependencyGraph"
CHECK="$ROOT/Scripts/check-dependency-graph.sh"
GOOD="$FIXTURES/manifest.json"

mutated() {   # <name> <jq filter> <text the report must hold>
    local name="$1" filter="$2" text="$3"
    LAST_OUTPUT="$(jq "$filter" "$GOOD" | "$CHECK" --manifest-json - 2>&1)"; LAST_STATUS=$?
    if [ "$LAST_STATUS" -ne 1 ]; then fail "$name (exit $LAST_STATUS, expected 1)" "$LAST_OUTPUT"; return; fi
    expect_contains "$name" "$text"
}

echo "check-dependency-graph"
expect_status 0 "a manifest that equals §4.2 passes" "$CHECK" --manifest-json "$GOOD"

mutated "an edge §4.2 does not have" \
    '(.targets[] | select(.name == "ZTronDSPCore") | .dependencies) += [{"byName": ["ZTronDSPDesign", null]}]' \
    "ZTronDSPCore depends on ZTronDSPDesign, which is listed below it (DEP-1)"
mutated "… is also reported as not listed" \
    '(.targets[] | select(.name == "ZTronDSPDesign") | .dependencies) += [{"byName": ["CZTronDSP", null]}]' \
    "ZTronDSPDesign depends on CZTronDSP, which §4.2 does not list for it"
mutated "a missing edge" \
    '(.targets[] | select(.name == "ZTronDSPAnalysis") | .dependencies) |= map(select(.byName[0] != "ZTronDSPMetal"))' \
    "ZTronDSPAnalysis does not depend on ZTronDSPMetal, which §4.2 lists for it"
mutated "a missing target" \
    '.targets |= map(select(.name != "ZTronDSPIO"))' \
    "target ZTronDSPIO of §4.2 is missing"
mutated "a target §4.2 does not have" \
    '.targets += [{"name": "ZTronDSPExtras", "type": "regular", "dependencies": [], "settings": []}]' \
    "target ZTronDSPExtras is not in §4.2"
mutated "the C half of the test product depending on Swift" \
    '(.targets[] | select(.name == "CZTronDSPTesting") | .dependencies) += [{"byName": ["ZTronDSPCore", null]}]' \
    "CZTronDSPTesting depends on ZTronDSPCore, which §4.2 does not list for it"
mutated "a third-party dependency" \
    '.dependencies += [{"sourceControl": [{"identity": "swift-atomics"}]}]' \
    "DEP-3 allows none"
mutated "a second platform" \
    '.platforms += [{"platformName": "macos", "version": "12.0", "options": []}]' \
    "PLAT-1 fixes [.iOS(.v15)]"
mutated "a higher floor" \
    '.platforms[0].version = "16.0"' \
    "PLAT-1 fixes [.iOS(.v15)]"
mutated "an older tools version" \
    '.toolsVersion._version = "6.0.0"' \
    "swift-tools-version is 6.0.0"
mutated "function-effect warnings that are not errors" \
    '(.targets[] | select(.name == "CZTronDSP") | .settings) |= map(select(.kind.treatWarning == null))' \
    "CZTronDSP does not turn function-effect warnings into errors"
mutated "unsafe flags" \
    '(.targets[] | select(.name == "ZTronDSPCore") | .settings) += [{"tool": "swift", "kind": {"unsafeFlags": {"_0": ["-Ounchecked"]}}}]' \
    "ZTronDSPCore uses unsafeFlags"
mutated "a target outside the Swift 6 mode" \
    '(.targets[] | select(.name == "ZTronDSPIO") | .settings) = []' \
    "ZTronDSPIO is not in the Swift 6 language mode"
mutated "a missing product" \
    '.products |= map(select(.name != "ZTronDSPUI"))' \
    "product ZTronDSPUI of §4.2 is missing"
mutated "a product §4.2 does not have" \
    '.products += [{"name": "ZTronDSPCore", "targets": ["ZTronDSPCore"], "type": {"library": ["automatic"]}, "settings": []}]' \
    "product ZTronDSPCore is not in §4.2"
mutated "a target without its test target" \
    '.targets |= map(select(.name != "ZTronDSPMetalTests"))' \
    "there is no test target ZTronDSPMetalTests"
mutated "a test target that does not depend on what it tests" \
    '(.targets[] | select(.name == "ZTronDSPDesignTests") | .dependencies) |= map(select(.byName[0] != "ZTronDSPDesign"))' \
    "ZTronDSPDesignTests does not depend on ZTronDSPDesign"
mutated "another C standard" \
    '.cLanguageStandard = "gnu17"' \
    "CZTronDSP is C11"

expect_status 0 "sources that import what §4.2 allows pass" "$CHECK" --manifest-json "$GOOD" --sources "$FIXTURES/sources-clean"
expect_status 1 "sources that import across the graph fail" "$CHECK" --manifest-json "$GOOD" --sources "$FIXTURES/sources-bad"
expect_contains "the core importing AVFAudio" "Sources/ZTronDSPCore/Capture.swift:1: ZTronDSPCore imports AVFAudio"
expect_contains "the core importing Metal" "Sources/ZTronDSPCore/Capture.swift:2: ZTronDSPCore imports Metal"
expect_contains "the core importing a target below it" "Sources/ZTronDSPCore/Capture.swift:3: ZTronDSPCore imports ZTronDSPDesign, which is not among its dependencies"
expect_contains "a target importing the C layer without depending on it" "Sources/ZTronDSPDesign/Kernel.swift:2: ZTronDSPDesign imports CZTronDSP"
expect_contains "an exported import across the graph" "Sources/ZTronDSPDesign/Kernel.swift:3: ZTronDSPDesign imports ZTronDSPAnalysis"
expect_contains "MetalKit outside the views" "Sources/ZTronDSPMetal/Host.swift:2: ZTronDSPMetal imports MetalKit; only ZTronDSPUI may (DEP-2)"
expect_contains "a C kernel including AVFAudio" "Sources/CZTronDSP/kernel.c:1: a C file includes AVFAudio"
expect_contains "the facade re-exporting the views" "Sources/ZTronDSP/Facade.swift:1: ZTronDSP imports ZTronDSPUI"
expect_lacks "what §4.2 allows is not reported" "Sources/ZTronDSPIO/Input.swift"

expect_status 2 "a missing manifest file is a usage error" "$CHECK" --manifest-json "$FIXTURES/absent.json"
expect_status 0 "the package itself equals §4.2" "$CHECK"
finish
