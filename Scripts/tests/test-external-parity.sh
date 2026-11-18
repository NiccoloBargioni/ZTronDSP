#!/bin/bash
# Self-test of Scripts/external-parity.sh (WP-907, WP-908; CI gate 9).
#
#   Scripts/tests/test-external-parity.sh          what needs no simulator
#   Scripts/tests/test-external-parity.sh --slow   also runs the parity tests on the simulator with
#                                                  a violation seeded in them: a re-implemented stage
#                                                  whose output differs from its twin's
#
# The seeded violations are made here, in copies of the external package and of the guide under
# a scratch folder: nothing is kept in the repository that breaks a rule on purpose. The checks
# that read a build of the external package (its compile fixtures, with a sentence seeded wrong)
# are skipped, loudly, when there is none: run Scripts/external-parity.sh --step build first.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
E="$ROOT/Scripts/external-parity.sh"
TREE="$ROOT/ExternalParity"
GUIDE="$ROOT/Docs/ExtensionGuide.md"
slow=0
for argument in "$@"; do
    case "$argument" in
        --slow) slow=1 ;;
        *) echo "test-external-parity: unknown argument $argument" >&2; exit 2 ;;
    esac
done
make_scratch external-parity
S="$SCRATCH"

echo "external-parity"

# ---------------------------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------------------------
expect_status 2 "an unknown argument is refused" "$E" --everything
expect_status 2 "a step that does not exist is refused" "$E" --step deploy
expect_contains "… and the steps are named" "rules guide build test fixtures release audits speed"
expect_status 2 "--launches takes a positive number" "$E" --launches 0
expect_status 2 "a package that is not there is a usage error" env ZTD_EXTERNAL_TREE="$S/nowhere" "$E" --step rules
expect_status 0 "--list says what each step runs" "$E" --list
expect_contains "… down to the last" "speed     The speed check, in Release"

# ---------------------------------------------------------------------------------------------
# rules: the external package as it is, and copies of it with one violation each
# ---------------------------------------------------------------------------------------------
# copy_tree <name>: a copy of the external package under the scratch folder, without build products.
copy_tree() {
    reset_folder "$S/$1"
    mkdir -p "$S/$1/ExternalParity"
    cp -R "$TREE/Package.swift" "$TREE/Sources" "$TREE/Tests" "$TREE/Docs" "$S/$1/ExternalParity/"
}
# seeded <step> <name> <file inside the package> <text to append>: the step on a copy with that text added.
seeded() {
    local step="$1" name="$2" file="$3" text="$4"
    copy_tree seeded
    printf '%s\n' "$text" >> "$S/seeded/ExternalParity/$file"
    expect_status 1 "$name" env ZTD_EXTERNAL_TREE="$S/seeded/ExternalParity" ZTD_EXTERNAL_DERIVED="$S/derived" "$E" --step "$step"
}
# replaced <file> <old> <new>: replaces the first occurrence of a text in a file, and fails loudly when it is not there.
replaced() {
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
if old not in text:
    sys.exit("the self-test's seed does not apply: %s lacks %r" % (path, old))
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}

expect_status 0 "the external package keeps its rules" env ZTD_EXTERNAL_DERIVED="$S/derived" "$E" --step rules
expect_contains "… and says what was held" "rules: clean"

seeded rules "@testable import fails the rules" Tests/ExternalStagesTests/GainParityTests.swift "@testable import ZTronDSP"
expect_contains "… as a hidden channel" "[EXT-4] \`@testable\`"
seeded rules "@_spi fails the rules" Sources/ExternalStages/Kernels/ExternalGain.swift "@_spi(Internal) import ZTronDSP"
expect_contains "… as a hidden channel" "[EXT-4] \`@_spi\`"
seeded rules "a target behind the products fails the rules" Sources/ExternalStages/Kernels/ExternalGain.swift "import ZTronDSPCore"
expect_contains "… and the three products are named" "\`import ZTronDSPCore\`: the external package imports the three products of ZTronDSP (ZTronDSP, ZTronDSPUI, ZTronDSPTesting)"
seeded rules "UIKit fails the rules, in a test too" Tests/ExtensionGuideTests/DisplayExampleTests.swift "import UIKit"
expect_contains "… by its name" "\`import UIKit\`"
seeded rules "Combine fails the rules" Tests/ExternalStagesTests/GainParityTests.swift "import Combine"
expect_contains "… by the package's own lint" "[APR-1] \`import Combine\`"
seeded rules "AnyView fails the rules" Sources/ExtensionGuideUI/NormalizedSpectrogram.swift "@MainActor let seeded = AnyView(EmptyView())"
expect_contains "… by the package's own lint" "[APR-1] \`AnyView\`"
seeded rules "SwiftUI outside the view target fails the rules" Sources/ExternalStages/Kernels/ExternalGain.swift "import SwiftUI"
expect_contains "… by the package's own lint" "[BIND-7]"
expect_lacks "… while the view target may import it" "Sources/ExtensionGuideUI/NormalizedSpectrogram.swift"
seeded rules "a for-in loop in a Nodes folder fails the rules" Sources/ExtensionGuide/Nodes/SpectralFlux.swift \
    "func seeded(_ values: [Float]) -> Float { var sum: Float = 0; for value in values { sum += value }; return sum }"
expect_contains "… as a hot-path ban" "[RT-7] \`for … in\` is banned in a hot directory"
seeded rules "an options object fails the rules" Sources/ExtensionGuide/Kernels/FeedbackComb.swift "public struct CombOptions: Sendable { public init() {} }"
expect_contains "… by its name" "[API-6]"
seeded rules "an unchecked Sendable type without a register entry fails the rules" Sources/ExtensionGuide/Kernels/Despike.swift \
    "final class Seeded: @unchecked Sendable {}"
expect_contains "… and the register is named" "[SEND] \`Seeded\` is \`@unchecked Sendable\` and has no entry"
seeded rules "a private header of ZTronDSP fails the rules" Sources/CExtensionGuide/extg_comb.c '#include "../../CZTronDSP/ztd_vdsp.h"'
expect_contains "… and the public headers are named" "includes its own headers and the public headers of ZTronDSP"

copy_tree manifest
replaced "$S/manifest/ExternalParity/Package.swift" '.product(name: "ZTronDSPTesting", package: "ZTronDSP")' '.product(name: "ZTronDSPCore", package: "ZTronDSP")'
expect_status 1 "a manifest that names a fourth product fails the rules" env ZTD_EXTERNAL_TREE="$S/manifest/ExternalParity" ZTD_EXTERNAL_DERIVED="$S/derived" "$E" --step rules
expect_contains "… and says which" "\`.product(name: \"ZTronDSPCore\", package: \"ZTronDSP\")\`"
copy_tree manifest
replaced "$S/manifest/ExternalParity/Package.swift" '.package(name: "ZTronDSP", path: "..")' '.package(name: "ZTronDSP", path: ".."), .package(url: "https://example.com/other.git", from: "1.0.0")'
expect_status 1 "a manifest with a second dependency fails the rules" env ZTD_EXTERNAL_TREE="$S/manifest/ExternalParity" ZTD_EXTERNAL_DERIVED="$S/derived" "$E" --step rules
expect_contains "… and says so" "depends on ZTronDSP by path"

# ---------------------------------------------------------------------------------------------
# guide: the guide as it is, and copies of it and of the sources that have drifted apart
# ---------------------------------------------------------------------------------------------
guide_step() { env ZTD_EXTERNAL_GUIDE="$S/guide.md" ZTD_EXTERNAL_DERIVED="$S/derived" "$@" "$E" --step guide; }

expect_status 0 "the guide shows what the external package compiles" env ZTD_EXTERNAL_DERIVED="$S/derived" "$E" --step guide
expect_contains "… a section for every row of §5.11.1" "guide: 11 rows of §5.11.1, each with its section"

cp "$GUIDE" "$S/guide.md"
replaced "$S/guide.md" "previous.copy(from: current, count: bins)" "previous.copy(from: current, count: bins - 1)"
expect_status 1 "a snippet of the guide that differs from its source by a few characters fails" guide_step
expect_contains "… and the file, the region and both lines are named" "the block differs from ExternalParity/Sources/ExtensionGuide/Nodes/SpectralFlux.swift#flux-node at its line"
expect_contains "… the guide's" "the guide has \`previous.copy(from: current, count: bins - 1)\`"

cp "$GUIDE" "$S/guide.md"
python3 - "$S/guide.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
start, end = text.index("## 6. A source"), text.index("## 7. A design or a strategy")
open(sys.argv[1], "w", encoding="utf-8").write(text[:start] + text[end:])
PY
expect_status 1 "a guide that leaves out a row of §5.11.1 fails" guide_step
expect_contains "… and the row is named" "there is no section for the row \"A source\" of §5.11.1"
expect_contains "… and so is the example that is no longer shown" "the marked region click-source is not shown in the guide"

cp "$GUIDE" "$S/guide.md"
printf '\n```swift\nlet shown = Pipeline { Gain(.decibels(-6)) }\n```\n' >> "$S/guide.md"
expect_status 1 "a code block that no compiled file backs fails" guide_step
expect_contains "… and says what to do" "a code block that no compiled file backs"

cp "$GUIDE" "$S/guide.md"
replaced "$S/guide.md" "SpectralFlux.swift#flux-node -->" "SpectralFlux.swift#flux-engine -->"
expect_status 1 "a snippet that names a region its file does not mark fails" guide_step
expect_contains "… and says so" "that file marks no region of this name"

cp "$GUIDE" "$S/guide.md"
replaced "$S/guide.md" "ExternalParity/Sources/ExtensionGuide/Nodes/SpectralFlux.swift#flux-stage" "Sources/ZTronDSPAnalysis/Steps/Level.swift#flux-stage"
expect_status 1 "a snippet from outside the external package fails" guide_step
expect_contains "… because only that package is compiled as a client" "a path of the guide begins with ExternalParity/"

cp "$GUIDE" "$S/guide.md"
python3 - "$S/guide.md" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
section = lines.index("## 5. A sink")
row = next(n for n in range(section, len(lines)) if lines[n].startswith("| Threading contract |"))
del lines[row]
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(lines))
PY
expect_status 1 "a section that does not state its threading contract fails" guide_step
expect_contains "… and the section and the fact are named" "the section \"A sink\" does not say: Threading contract"

cp "$GUIDE" "$S/guide.md"
copy_tree drift
replaced "$S/drift/ExternalParity/Sources/ExtensionGuide/Kernels/Despike.swift" "older = newer" "older = current"
expect_status 1 "a source that changed under the guide fails" guide_step ZTD_EXTERNAL_TREE="$S/drift/ExternalParity"
expect_contains "… and the compiled line is shown beside the guide's" "the compiled source \`older = current\`"

copy_tree drift
printf '// snippet:begin unshown\nlet unshown = 0\n// snippet:end unshown\n' >> "$S/drift/ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift"
expect_status 1 "a marked region that the guide does not show fails" guide_step ZTD_EXTERNAL_TREE="$S/drift/ExternalParity"
expect_contains "… and is named" "the marked region unshown is not shown in the guide"

copy_tree drift
printf '// snippet:begin open\nlet open = 0\n' >> "$S/drift/ExternalParity/Sources/ExtensionGuide/Designs/SineWindow.swift"
expect_status 1 "a region that never ends fails" guide_step ZTD_EXTERNAL_TREE="$S/drift/ExternalParity"
expect_contains "… and is named" "the region open never ends"

expect_status 1 "without the specification the rows cannot be read" guide_step ZTD_EXTERNAL_SPECIFICATION="$S/absent.md"
expect_contains "… and the step says so" "there is no specification"

# ---------------------------------------------------------------------------------------------
# build, test, fixtures, release, audits, speed, with stand-ins for xcodebuild, Scripts/xc.sh
# and Scripts/compile-fixtures.sh that record how they were called
# ---------------------------------------------------------------------------------------------
cat > "$S/xcodebuild" <<'STUB'
#!/bin/bash
action=""; config=""; only=""; parallel="yes"; derived=""; destination=""; coverage=""; scheme=""
while [ $# -gt 0 ]; do
    case "$1" in
        build-for-testing|test-without-building) action="$1" ;;
        -scheme) scheme="$2"; shift ;;
        -configuration) config="$2"; shift ;;
        -only-testing:*) only="$only ${1#-only-testing:}" ;;
        -parallel-testing-enabled) parallel="$2"; shift ;;
        -derivedDataPath) derived="$2"; shift ;;
        -destination) destination="$2"; shift ;;
        -enableCodeCoverage) coverage="$2"; shift ;;
    esac
    shift
done
echo "xcodebuild $action $config [only:$only] [parallel $parallel] [seed ${TEST_RUNNER_ZTD_EXTERNAL_SEEDED_VIOLATION:-}] [bench ${TEST_RUNNER_ZTD_BENCHMARK_OUTPUT:+yes}]" >> "$STUB_LOG"
echo "$scheme|$coverage|$destination|$derived|$(pwd -P)" >> "$STUB_LOG.settings"
case "$action" in
    build-for-testing)
        if [ "${STUB_FAIL:-}" = "build-$config" ]; then
            echo "Seeded.swift:1:1: error: seeded build failure"; echo "** TEST BUILD FAILED **"; exit 65
        fi
        echo "** TEST BUILD SUCCEEDED **" ;;
    test-without-building)
        kind="tests"
        case "$only" in *SpeedTests*) kind="speed" ;; *AllocationAudit*) kind="audits" ;; esac
        count_file="$STUB_LOG.count.$kind"
        count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); echo "$count" > "$count_file"
        failing=0
        case "${STUB_FAIL:-}" in
            "$kind") failing=1 ;;
            "$kind-first") [ "$count" -eq 1 ] && failing=1 ;;
            "$kind-empty") echo "	 Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds"; echo "** TEST EXECUTE SUCCEEDED **"; exit 0 ;;
        esac
        if [ "$kind" = "speed" ]; then
            echo "SPEED ExternalLowPass, order 8 against stock LowPass, order 8: ×1.000 round by round (quartiles ×0.999 … ×1.001 over 30 rounds); ×0.999 by the least times, ×1.000 by the medians"
            [ "${STUB_FAIL:-}" = "speed-unrecorded" ] || printf '{"results": []}\n' > "$TEST_RUNNER_ZTD_BENCHMARK_OUTPUT"
        fi
        if [ "$failing" -eq 1 ]; then
            echo "✘ Test seeded() recorded an issue at Seeded.swift:1:1: Expectation failed: external == stock"
            echo "✘ Test run with 5 tests in 2 suites failed after 0.100 seconds with 1 issue."
            echo "** TEST EXECUTE FAILED **"
            exit 65
        fi
        echo "◇ Test control() recorded a known issue at Audit.swift:41:59: Expectation failed: counts.allocations == 0"
        echo "✔ Test run with 5 tests in 2 suites passed after 0.100 seconds with 1 known issue."
        echo "** TEST EXECUTE SUCCEEDED **" ;;
esac
exit 0
STUB
cat > "$S/xc.sh" <<'STUB'
#!/bin/bash
echo "xc $* [device ${ZTD_DEVICE:-default}]" >> "$STUB_LOG"
[ "${STUB_FAIL:-}" = "device" ] && exit 1
echo "STUB-UDID"
STUB
cat > "$S/fixtures.sh" <<'STUB'
#!/bin/bash
echo "fixtures [config ${ZTD_CONFIG:-}] [derived ${ZTD_DERIVED:-}] [cpath ${CPATH:-}] $*" >> "$STUB_LOG"
echo "compile-fixtures: 2 valid fixtures compile, 21 invalid fixtures fail with their sentences"
exit "${STUB_FIXTURES_STATUS:-0}"
STUB
chmod +x "$S/xcodebuild" "$S/xc.sh" "$S/fixtures.sh"
run_stub() {
    : > "$S/log"; : > "$S/log.settings"; rm -f "$S"/log.count.*
    env STUB_LOG="$S/log" ZTD_EXTERNAL_XC="$S/xc.sh" ZTD_EXTERNAL_XCODEBUILD="$S/xcodebuild" ZTD_EXTERNAL_FIXTURES="$S/fixtures.sh" \
        ZTD_EXTERNAL_DERIVED="$S/derived" "$@"
}
# calls: what the stand-ins were asked, one call per line, without the simulator look-ups.
calls() { grep -v "^xc device" "$S/log"; }

expect_status 0 "every step passes when the builds and the tests do" run_stub "$E"
expected="xcodebuild build-for-testing Debug [only:] [parallel yes] [seed ] [bench ]
xcodebuild test-without-building Debug [only:] [parallel yes] [seed ] [bench ]
fixtures [config Debug] [derived $S/derived] [cpath $ROOT/Sources/CZTronDSP/include] --valid $TREE/Tests/CompileFixtures/valid --invalid $TREE/Tests/CompileFixtures/invalid
xcodebuild build-for-testing Release [only:] [parallel yes] [seed ] [bench ]
xcodebuild test-without-building Release [only: ExternalStagesTests/AllocationAuditTests ExtensionGuideTests/GuideAllocationAuditTests] [parallel yes] [seed ] [bench ]
xcodebuild test-without-building Release [only: ExternalStagesTests/SpeedTests] [parallel NO] [seed ] [bench yes]"
if [ "$(env CPATH= true; calls | sed -E "s|\[cpath ([^]:]*)[^]]*\]|[cpath \1]|")" = "$expected" ]; then
    pass "… in order: Debug build and tests, the fixtures against it, Release build, the audits, the speed check by itself"
else
    fail "… in order: Debug build and tests, the fixtures against it, Release build, the audits, the speed check by itself" "$(calls)"
fi
if [ "$(sort -u "$S/log.settings")" = "ExternalParity-Package|NO|platform=iOS Simulator,id=STUB-UDID|$S/derived|$(cd "$TREE" && pwd -P)" ]; then
    pass "… each on the package's scheme, without coverage, on the simulator, into the derived data of its own"
else
    fail "… each on the package's scheme, without coverage, on the simulator, into the derived data of its own" "$(sort -u "$S/log.settings")"
fi
expect_contains "… the rules and the guide were held first" "external-parity: guide     passed"
expect_contains "… the summary names every step" "external-parity: speed     passed"
expect_contains "… an expectation that is known to fail is shown, not hidden" "Test control() recorded a known issue at Audit.swift:41:59"
expect_contains "… the figures of the speed check are shown" "ExternalLowPass, order 8 against stock LowPass, order 8: ×1.000"
if [ -s "$S/derived/speed.json" ] && [ -s "$S/derived/logs/test.log" ]; then
    pass "… and the logs and the figures are kept under the derived data"
else
    fail "… and the logs and the figures are kept under the derived data" "$(ls -R "$S/derived")"
fi

expect_status 0 "ZTD_DEVICE names the simulator" run_stub env ZTD_DEVICE=some-phone "$E" --step build
if grep -q "^xc device \[device some-phone\]" "$S/log"; then pass "… and reaches Scripts/xc.sh"; else fail "… and reaches Scripts/xc.sh" "$(cat "$S/log")"; fi
expect_status 1 "no simulator: the step fails" run_stub env STUB_FAIL=device "$E" --step build
expect_contains "… and says so" "there is no simulator to run on"

expect_status 1 "a Debug build that fails fails the run" run_stub env STUB_FAIL=build-Debug "$E"
expect_contains "… with the compiler's words" "Seeded.swift:1:1: error: seeded build failure"
if [ "$(calls | wc -l | tr -d ' ')" -eq 1 ]; then pass "… and nothing is tested after it"; else fail "… and nothing is tested after it" "$(calls)"; fi

expect_status 1 "a failing test fails the run" run_stub env STUB_FAIL=tests "$E"
expect_contains "… the step is named" "external-parity: [test] FAILED"
expect_contains "… and the test that failed" "Test seeded() recorded an issue at Seeded.swift:1:1"
if calls | grep -q "Release"; then fail "… and the run stops there" "$(calls)"; else pass "… and the run stops there"; fi
expect_status 1 "--keep-going runs the remaining steps and still fails" run_stub env STUB_FAIL=tests "$E" --keep-going
if calls | grep -q "SpeedTests"; then pass "… down to the speed check"; else fail "… down to the speed check" "$(calls)"; fi
expect_contains "… and the summary shows which step failed" "external-parity: test      FAILED"
expect_status 1 "a run in which no test ran fails" run_stub env STUB_FAIL=tests-empty "$E" --step test
expect_contains "… because it proves nothing" "no test ran"
expect_status 1 "an audit that fails in Release fails the run" run_stub env STUB_FAIL=audits "$E"
if calls | grep -q "SpeedTests"; then fail "… before the speed check" "$(calls)"; else pass "… before the speed check"; fi

expect_status 0 "a speed check that holds its bound at the second launch passes" run_stub env STUB_FAIL=speed-first "$E" --step speed
expect_contains "… and says which launch" "launch 2 of 3"
expect_status 1 "a speed check that never holds its bound fails" run_stub env STUB_FAIL=speed "$E" --step speed
if [ "$(calls | grep -c SpeedTests)" -eq 3 ]; then pass "… after three launches"; else fail "… after three launches" "$(calls)"; fi
expect_contains "… and says so" "the speed check did not hold in 3 launches"
expect_status 1 "--launches chooses how many" run_stub env STUB_FAIL=speed-first "$E" --step speed --launches 1
if [ "$(calls | grep -c SpeedTests)" -eq 1 ]; then pass "… here one"; else fail "… here one" "$(calls)"; fi
expect_status 1 "a speed suite that passes without recording did not hold its bounds" run_stub env STUB_FAIL=speed-unrecorded "$E" --step speed --launches 1
expect_contains "… and the step says why" "it did not run as a benchmark"

expect_status 0 "a seeded violation is handed to the tests" run_stub env ZTD_EXTERNAL_SEEDED_VIOLATION=gain "$E" --step test --step audits
if [ "$(calls)" = "xcodebuild test-without-building Debug [only:] [parallel yes] [seed gain] [bench ]
xcodebuild test-without-building Release [only: ExternalStagesTests/AllocationAuditTests ExtensionGuideTests/GuideAllocationAuditTests] [parallel yes] [seed ] [bench ]" ]; then
    pass "… of the test step, and of no other"
else
    fail "… of the test step, and of no other" "$(calls)"
fi
expect_contains "… and the run says that it is seeded" "a violation is seeded on purpose: gain"

expect_status 1 "a fixture that misbehaves fails the run" run_stub env STUB_FIXTURES_STATUS=1 "$E" --step fixtures
expect_contains "… and says so" "a fixture misbehaves"
expect_status 1 "no fixture at all fails the run" run_stub env STUB_FIXTURES_STATUS=3 "$E" --step fixtures
expect_contains "… and says so" "no fixture was found"

expect_status 0 "steps run in the order of the list, whatever the order they are named in" run_stub "$E" --step speed --step release
if [ "$(calls | sed -E 's/ \[only.*//')" = "xcodebuild build-for-testing Release
xcodebuild test-without-building Release" ]; then pass "… the build before the check"; else fail "… the build before the check" "$(calls)"; fi

expect_status 1 "a step that needs a build says so when there is none" env ZTD_EXTERNAL_DERIVED="$S/empty" "$E" --step fixtures
expect_contains "… and which step makes one" "there is no Debug build under $S/empty: run the step build first"

# ---------------------------------------------------------------------------------------------
# The fixtures against a real build of the external package: as they are, and with seeds
# ---------------------------------------------------------------------------------------------
REAL="${ZTD_EXTERNAL_DERIVED:-$ROOT/.build/external-parity}"
if [ -d "$REAL/Build/Products/Debug-iphonesimulator/ExternalStages.swiftmodule" ]; then
    expect_status 0 "the fixtures of the external package behave against its build" "$E" --step fixtures
    expect_contains "… the invalid ones fail with their sentences" "invalid fixtures fail with their sentences"

    fixtures_copy() {
        reset_folder "$S/fixtures"
        mkdir -p "$S/fixtures/ExternalParity/Tests"
        cp "$TREE/Package.swift" "$S/fixtures/ExternalParity/"
        cp -R "$TREE/Tests/CompileFixtures" "$S/fixtures/ExternalParity/Tests/"
    }
    fixtures_copy
    replaced "$S/fixtures/ExternalParity/Tests/CompileFixtures/invalid/O-05-ExternalMelScaleAfterDecibels.swift" \
        "// expect: ExternalMelScale needs" "// expect: MelScale wants"
    expect_status 1 "a fixture whose sentence is wrong fails the gate" env ZTD_EXTERNAL_TREE="$S/fixtures/ExternalParity" "$E" --step fixtures
    expect_contains "… and the sentence that was not given is named" "it fails, but not with the sentence: MelScale wants"
    expect_contains "… with the compiler's own words" "ExternalMelScale needs a linear-frequency spectrum of magnitudes or powers"

    fixtures_copy
    replaced "$S/fixtures/ExternalParity/Tests/CompileFixtures/invalid/O-05-ExternalMelScaleAfterDecibels.swift" "Decibels(); ExternalMelScale" "ExternalMelScale"
    expect_status 1 "a must-not-compile fixture that compiles fails the gate" env ZTD_EXTERNAL_TREE="$S/fixtures/ExternalParity" "$E" --step fixtures
    expect_contains "… and says so" "it is filed as invalid and compiles"

    fixtures_copy
    printf 'let seeded: Pipeline<Samples, Samples> = Pipeline { STFT(frame: 1_024, hop: 256); ExternalGain(.decibels(-3)) }\n' \
        >> "$S/fixtures/ExternalParity/Tests/CompileFixtures/valid/ExternalStagesWhereTheirTwinsStand.swift"
    expect_status 1 "a fixture that must compile and does not fails the gate" env ZTD_EXTERNAL_TREE="$S/fixtures/ExternalParity" "$E" --step fixtures
    expect_contains "… and says so" "it is filed as valid and does not compile"

    if [ "$slow" -eq 1 ]; then
        expect_status 1 "a re-implemented stage whose output differs from its twin's fails the gate" env ZTD_EXTERNAL_SEEDED_VIOLATION=gain "$E" --step test
        expect_contains "… in the parity test of the gain" "outputEqualsTheStockGainBitForBit"
        expect_contains "… and the run says that the violation was seeded" "a violation is seeded on purpose: gain"
    else
        echo "  SKIP  the parity tests on the simulator with a seeded violation (run this test with --slow)"
    fi
else
    echo "  SKIP  the fixtures of the external package, as they are and with a sentence seeded wrong: there is no build under $REAL (run Scripts/external-parity.sh --step build)"
    [ "$slow" -eq 1 ] && echo "  SKIP  the parity tests on the simulator with a seeded violation: there is no build under $REAL"
fi
echo "  NOTE  build, test, release, audits and speed were exercised through stand-ins: this self-test runs no simulator test unless --slow is given"

finish
