#!/bin/bash
# Self-test of Scripts/ci.sh (WP-014).
#
# Part 1 runs ci.sh among stand-ins for every tool it calls, to test the order of the gates and
# what a failure or a missing input does. Part 2 runs the real scripts on a copy of the package
# with one violation seeded per gate. No simulator test is run: gate 5 is exercised through its
# stand-in only. `--slow` adds the real builds of gate 1 (a seeded compiler warning).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
SLOW=0; [ "${1:-}" = "--slow" ] && SLOW=1
make_scratch ci-test

echo "ci"

# ---------------------------------------------------------------------------------------------
# Part 1: orchestration, among stand-ins
# ---------------------------------------------------------------------------------------------
S="$SCRATCH/standins"
mkdir -p "$S/Scripts/ci" "$S/Tests/ZTronDSPCoreTests" "$S/products/ZTronDSPCore.swiftmodule" "$S/bin"
cp "$ROOT/Scripts/ci.sh" "$S/Scripts/ci.sh"
# The scratch tree starts with the file's header and no filter: the tests below add their own.
grep '^#' "$ROOT/Scripts/ci/allocation-audit-filters.txt" > "$S/Scripts/ci/allocation-audit-filters.txt"
export STUB_LOG="$S/log"
standin() {   # <path> <name in the log> : a script that logs its call and exits with $STUB_<NAME>, default 0
    local variable="STUB_$(printf '%s' "$2" | tr 'a-z-' 'A-Z_')"
    printf '#!/bin/bash\necho "%s $*" >> "$STUB_LOG"\nexit "${%s:-0}"\n' "$2" "$variable" > "$1"
    chmod +x "$1"
}
for tool in lint-bans check-dependency-graph compile-fixtures api-digest docs coverage-gate golden benchmarks external-parity order-matrix; do
    standin "$S/Scripts/$tool.sh" "$tool"
done
# The golden stand-in answers the Octave run (--octave) with $STUB_GOLDEN_OCTAVE, everything else with $STUB_GOLDEN.
printf '#!/bin/bash\necho "golden $*" >> "$STUB_LOG"\ncase " $* " in *" --octave "*) exit "${STUB_GOLDEN_OCTAVE:-0}" ;; esac\nexit "${STUB_GOLDEN:-0}"\n' > "$S/Scripts/golden.sh"
cat > "$S/bin/xc" <<'EOS'
#!/bin/bash
echo "xc $* [config=${ZTD_CONFIG:-} device=${ZTD_DEVICE:-} derived=${ZTD_DERIVED##*/} xcargs=${ZTD_XCARGS:-}]" >> "$STUB_LOG"
case "${1:-}" in
    products) echo "$STUB_PRODUCTS" ;;
    device) echo "FAKE-UDID" ;;
    build) exit "${STUB_XC_BUILD:-0}" ;;
    test-only)
        # xcodebuild leaves a result bundle where it is told to.
        bundle="$(printf '%s' "${ZTD_XCARGS:-}" | sed -n -E 's/.*-resultBundlePath ([^ ]+).*/\1/p')"
        [ -n "$bundle" ] && mkdir -p "$STUB_ROOT/$bundle"
        [ "${ZTD_DEVICE:-}" = "${STUB_XC_FAILING_DEVICE:-none}" ] && exit 1
        exit "${STUB_XC_TEST_ONLY:-0}" ;;
    test) exit "${STUB_XC_TEST:-0}" ;;
esac
EOS
cat > "$S/bin/xcodebuild" <<'EOS'
#!/bin/bash
echo "xcodebuild $* [in=$PWD]" >> "$STUB_LOG"
exit "${STUB_XCODEBUILD:-0}"
EOS
cat > "$S/bin/simctl" <<'EOS'
#!/bin/bash
echo "simctl $*" >> "$STUB_LOG"
if [ "$1 $2 ${3:-}" = "list runtimes -j" ]; then
    cat <<'JSON'
{"runtimes": [
 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-0", "isAvailable": false, "supportedDeviceTypes": []},
 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-17-5", "isAvailable": true, "supportedDeviceTypes": [
   {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPad-10", "productFamily": "iPad"},
   {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro", "productFamily": "iPhone"}]},
 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-4", "isAvailable": true, "supportedDeviceTypes": [
   {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", "productFamily": "iPhone"}]},
 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-6", "isAvailable": true, "supportedDeviceTypes": [
   {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro", "productFamily": "iPhone"}]},
 {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0", "isAvailable": true, "supportedDeviceTypes": [
   {"identifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", "productFamily": "iPhone"}]}
]}
JSON
elif [ "$1 $2" = "list devices" ]; then
    # STUB_SIMCTL_BOOTED names the simulator that was booted before the run.
    if [ "${STUB_SIMCTL_BOOTED:-}" = "ztdsp-ci-18-6" ]; then state=Booted; else state=Shutdown; fi
    echo "    ztdsp-ci-18-6 (00000000-0000-0000-0000-000000000186) ($state)"
elif [ "$1" = "create" ]; then
    echo "11111111-1111-1111-1111-111111111111"
fi
EOS
# The gallery's script: `hosted` says what Swift Testing says, and records a known issue on the
# simulator STUB_GALLERY_KNOWN names (`any`: on every one).
cat > "$S/bin/gallery" <<'EOS'
#!/bin/bash
echo "gallery $* [config=${ZTD_CONFIG:-} device=${ZTD_DEVICE:-} derived=${ZTD_DERIVED##*/}]" >> "$STUB_LOG"
case "${1:-}" in
    app) exit "${STUB_GALLERY_APP:-0}" ;;
    hosted)
        if [ "${STUB_GALLERY_KNOWN:-none}" = "any" ] || [ "${STUB_GALLERY_KNOWN:-none}" = "${ZTD_DEVICE:-}" ]; then
            echo "◇ Test aHostedExpectation() recorded a known issue at Hosted.swift:9:9: Expectation failed"
            echo "✔ Test run with 24 tests in 8 suites passed after 9.000 seconds with 1 known issue."
        else
            echo "✔ Test run with 24 tests in 8 suites passed after 9.000 seconds."
        fi
        exit "${STUB_GALLERY_HOSTED:-0}" ;;
    ui) exit "${STUB_GALLERY_UI:-0}" ;;
esac
EOS
chmod +x "$S/bin/xc" "$S/bin/xcodebuild" "$S/bin/simctl" "$S/bin/gallery"
export ZTD_CI_XC="$S/bin/xc" ZTD_CI_XCODEBUILD="$S/bin/xcodebuild" ZTD_CI_SIMCTL="$S/bin/simctl" ZTD_CI_GALLERY="$S/bin/gallery" STUB_PRODUCTS="$S/products" STUB_ROOT="$S"
unset ZTD_DERIVED ZTD_DEVICE ZTD_CI_COVERAGE_REPORT ZTD_CI_CHANGED_FILES ZTD_CI_BASE_REF GITHUB_ACTIONS
CI="$S/Scripts/ci.sh"

ci() { : > "$STUB_LOG"; expect_status "$1" "$2" "${@:3}"; }
logged() { if grep -q -F -- "$2" "$STUB_LOG"; then pass "$1"; else fail "$1 (the log lacks: $2)" "$(cat "$STUB_LOG")"; fi; }
not_logged() { if grep -q -F -- "$2" "$STUB_LOG"; then fail "$1 (the log holds: $2)" "$(cat "$STUB_LOG")"; else pass "$1"; fi; }

ci 0 "with every tool succeeding, no gate fails" "$CI"
expect_contains "… and every gate reports" "ci: gate 9  external parity                      passed"
order="$(sed -E 's/ .*//' "$STUB_LOG" | awk '!seen[$0]++' | tr '\n' ' ')"
if [ "$order" = "xc xcodebuild gallery lint-bans check-dependency-graph compile-fixtures order-matrix api-digest docs coverage-gate golden benchmarks external-parity " ]; then
    pass "the gates run in the order of §10.3"
else
    fail "the gates run in the order of §10.3" "$order"
fi
logged "gate 1 builds each production scheme for the simulator with warnings as errors" "xcodebuild build -scheme ZTronDSPUI -destination platform=iOS Simulator,id=FAKE-UDID"
logged "… and for a device" "xcodebuild build -scheme ZTronDSP -destination generic/platform=iOS"
logged "… with the three settings, the Metal compiler's among them (DEP-4)" "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES MTL_TREAT_WARNINGS_AS_ERRORS=YES"
logged "… from inside the package, wherever ci.sh was started" "CODE_SIGNING_ALLOWED=NO [in=$S]"
logged "gate 1 builds the gallery application in Release, in derived data of its own" "gallery app [config=Release device= derived=ci-gallery-release]"
logged "gate 5 runs the tests in Debug with coverage and a result bundle" "xc test-only [config=Debug device= derived=ci xcargs=-enableCodeCoverage YES -resultBundlePath .build/ci-results/Debug.xcresult]"
logged "… and the gallery's hosted suites, in Debug, in derived data of their own" "gallery hosted [config=Debug device= derived=ci-gallery]"
not_logged "the UI tests are not a gate" "gallery ui"
logged "gate 4 checks the digest" "api-digest --check"
logged "… and the documentation of every public symbol (WP-901b)" "docs --audit"
not_logged "… but builds no documentation: that is no gate" "docs --build"
logged "gate 7 checks the manifest" "golden --check"
logged "… and runs the golden MATLAB scripts under GNU Octave (WP-910)" "golden --octave"
logged "gate 8 checks the benchmarks" "benchmarks --check"

for case in "1:STUB_XCODEBUILD:build" "1:STUB_XC_BUILD:build" "1:STUB_GALLERY_APP:build" "5:STUB_GALLERY_HOSTED:tests" "2:STUB_LINT_BANS:lint and dependency graph" "2:STUB_CHECK_DEPENDENCY_GRAPH:lint and dependency graph" \
            "3:STUB_COMPILE_FIXTURES:compile fixtures and order matrix" "3:STUB_ORDER_MATRIX:compile fixtures and order matrix" "4:STUB_API_DIGEST:API digest and documentation" "4:STUB_DOCS:API digest and documentation" \
            "5:STUB_XC_TEST_ONLY:tests" "6:STUB_COVERAGE_GATE:coverage" "7:STUB_GOLDEN:golden vectors" "8:STUB_BENCHMARKS:benchmarks" "9:STUB_EXTERNAL_PARITY:external parity"; do
    gate="${case%%:*}"; rest="${case#*:}"; variable="${rest%%:*}"; name="${rest#*:}"
    ci 1 "a failure of ${variable#STUB_} fails gate $gate" env "$variable=1" "$CI"
    expect_contains "… which is reported" "$(printf 'ci: gate %s  %-36s FAILED' "$gate" "$name")"
    if [ "$gate" != "9" ]; then
        if printf '%s\n' "$LAST_OUTPUT" | grep -q -E "^ci: gate $((gate + 1))  .* not run$"; then pass "… and the gate after it does not run"; else fail "… and the gate after it does not run" "$(printf '%s\n' "$LAST_OUTPUT" | tail -12)"; fi
    fi
done

ci 1 "with --keep-going the gates after a failure still run" env STUB_LINT_BANS=1 "$CI" --keep-going
expect_contains "… the failed one is still failed" "ci: gate 2  lint and dependency graph            FAILED"
expect_contains "… and the last one ran" "ci: gate 9  external parity                      passed"
expect_lacks "… none is left out" "not run"

ci 0 "named gates run alone, in order whatever the order they were named in" "$CI" --gate 7 --gate 2
order="$(sed -E 's/ .*//' "$STUB_LOG" | tr '\n' ' ')"
if [ "$order" = "lint-bans check-dependency-graph golden golden " ]; then pass "… gate 2 before gate 7 (its manifest check, then its Octave run), and nothing else"; else fail "… gate 2 before gate 7 (its manifest check, then its Octave run), and nothing else" "$order"; fi

# Inputs that do not exist yet are skipped loudly.
rm "$S/Scripts/benchmarks.sh" "$S/Scripts/external-parity.sh" "$S/Scripts/order-matrix.sh"
ci 0 "gates whose inputs do not exist are skipped, and the run does not fail" "$CI"
expect_contains "the benchmark gate says it was skipped, and why" "ci: [gate 8] SKIPPED: the benchmark regression check: Scripts/benchmarks.sh does not exist yet"
expect_contains "the external parity gate too" "ci: gate 9  external parity                      SKIPPED"
expect_contains "a gate with one part missing passes in part" "ci: gate 3  compile fixtures and order matrix    PASSED IN PART — skipped: the order matrix"
ci 1 "under --strict a skipped part fails the run" "$CI" --strict --gate 3
expect_contains "… and the verdict says that a skip counted" "ci: --strict: a skipped gate counts as a failure"
ci 1 "under --strict a skipped gate fails the run" "$CI" --strict --gate 8
ci 1 "under --strict a gate that fails, with nothing skipped" env STUB_LINT_BANS=1 "$CI" --strict --gate 2
expect_lacks "… is not put down to a skip (WP-906)" "a skipped gate counts as a failure"
ci 0 "GitHub gets a warning annotation for a skip" env GITHUB_ACTIONS=true "$CI" --gate 9
expect_contains "… with the gate in its title" "::warning title=CI gate 9 (external parity) skipped::"
ci 1 "… and an error annotation for a failure" env GITHUB_ACTIONS=true STUB_GOLDEN=1 "$CI" --gate 7
expect_contains "… with the gate in its title" "::error title=CI gate 7 (golden vectors)::"
ci 0 "no compile fixture at all is a skip, not a pass" env STUB_COMPILE_FIXTURES=3 "$CI" --gate 3
expect_contains "… and says so" "SKIPPED: there is no compile fixture"
mkdir -p "$S/.build/ci-results/Debug.xcresult"
ci 0 "a coverage report without production code is a skip" env STUB_COVERAGE_GATE=3 "$CI" --gate 6
logged "… read from the result bundle of gate 5" "coverage-gate --xcresult $S/.build/ci-results/Debug.xcresult --mode aggregate --mode per-target"
expect_contains "… and says so" "SKIPPED: coverage: the report holds no executable line"
reset_folder "$S/.build/ci-results"
ci 0 "coverage without a result bundle is a skip" "$CI" --gate 6
expect_contains "… that names the gate to run first" "there is no result bundle at .build/ci-results/Debug.xcresult: run gate 5 first"
not_logged "… and the coverage gate is not called" "coverage-gate"
ci 0 "a coverage report can be named instead" env ZTD_CI_COVERAGE_REPORT="/tmp/a.json /tmp/b.json" "$CI" --gate 6
logged "… and reaches the coverage gate" "coverage-gate --report /tmp/a.json --report /tmp/b.json --mode aggregate --mode per-target"
printf 'Sources/ZTronDSPCore/A.swift\n' > "$S/changed.txt"
ci 0 "a list of changed files adds the COV-3 check" env ZTD_CI_COVERAGE_REPORT="/tmp/a.json" ZTD_CI_CHANGED_FILES="$S/changed.txt" "$CI" --gate 6
logged "… in the changed-files mode" "coverage-gate --report /tmp/a.json --mode changed-files"
ci 1 "the strict golden check fails on pending generators" env STUB_GOLDEN=3 "$CI" --strict --gate 7
logged "… and was asked to be strict" "golden --check --strict"
ci 1 "a golden script that fails under GNU Octave fails gate 7" env STUB_GOLDEN_OCTAVE=1 "$CI" --gate 7
expect_contains "… which is reported" "$(printf 'ci: gate 7  %-36s FAILED — the golden MATLAB scripts under GNU Octave' 'golden vectors')"
ci 0 "without GNU Octave the Octave run is skipped, and the gate passes in part" env STUB_GOLDEN_OCTAVE=3 "$CI" --gate 7
expect_contains "… loudly, with what to install" "ci: [gate 7] SKIPPED: the golden MATLAB scripts under GNU Octave: Octave is not installed (brew install octave)"
expect_contains "… as a gate passed in part" "$(printf 'ci: gate 7  %-36s PASSED IN PART' 'golden vectors')"
ci 1 "… and under --strict that skip fails the run" env STUB_GOLDEN_OCTAVE=3 "$CI" --strict --gate 7

# Gate 5: the matrix, the Release run of the allocation audit, the Thread Sanitizer.
ci 0 "the matrix runs the tests once per runtime of PLAT-3 that is installed" "$CI" --gate 5 --matrix
expect_contains "… and reports the one that is missing" "SKIPPED: the iOS 26.x simulator runtime of PLAT-3 is not installed"
logged "iOS 17.5 gets a simulator of a type that runtime supports" "simctl create ztdsp-ci-17-5 com.apple.CoreSimulator.SimDeviceType.iPhone-15-Pro com.apple.CoreSimulator.SimRuntime.iOS-17-5"
not_logged "a simulator that exists is not created again" "simctl create ztdsp-ci-18-6"
not_logged "the newest 18.x is the one that runs" "ztdsp-ci-18-4"
logged "the first runtime carries the result bundle" "xc test-only [config=Debug device=ztdsp-ci-17-5 derived=ci xcargs=-enableCodeCoverage YES -resultBundlePath .build/ci-results/Debug.xcresult]"
logged "the others run without it" "xc test-only [config=Debug device=ztdsp-ci-27-0 derived=ci xcargs=-enableCodeCoverage YES]"
ci 1 "a failure on one runtime fails the gate" env STUB_XC_FAILING_DEVICE=ztdsp-ci-18-6 "$CI" --gate 5 --matrix
logged "… after the other runtimes ran" "device=ztdsp-ci-27-0"
ci 0 "a named runtime runs alone" "$CI" --gate 5 --runtime com.apple.CoreSimulator.SimRuntime.iOS-27-0
not_logged "… and no other" "ztdsp-ci-17-5"

# A simulator of the matrix that the run booted is shut down after its runs (WP-906): one is
# booted at a time, not four.
ci 0 "a simulator of the matrix that the run boots" "$CI" --gate 5 --matrix
logged "… is shut down after its runs" "simctl shutdown 00000000-0000-0000-0000-000000000186"
expect_contains "… which is said" "shut down ztdsp-ci-18-6, which this run booted"
order="$(grep -F -e 'gallery hosted [config=Debug device=ztdsp-ci-18-6' -e 'simctl shutdown 00000000-0000-0000-0000-000000000186' -e 'xc test-only [config=Debug device=ztdsp-ci-27-0' "$STUB_LOG" | sed -E 's/ .*//' | tr '\n' ' ')"
if [ "$order" = "gallery simctl xc " ]; then pass "… after its hosted suites, before the next runtime's tests"; else fail "… after its hosted suites, before the next runtime's tests" "$order"; fi
ci 0 "a simulator of the matrix that was booted before the run" env STUB_SIMCTL_BOOTED=ztdsp-ci-18-6 "$CI" --gate 5 --matrix
not_logged "… is left booted" "simctl shutdown"
ci 0 "the device of Scripts/xc.sh, without --runtime or --matrix" env ZTD_DEVICE=ztdsp-ci-18-6 "$CI" --gate 5
not_logged "… is left as it is" "simctl shutdown"
ci 0 "the nightly job on the matrix" "$CI" --nightly --matrix
logged "… shuts down the simulator it booted, after its UI tests" "simctl shutdown 00000000-0000-0000-0000-000000000186"

# Gate 5: the gallery's hosted suites, on each simulator of the matrix, with no known issue.
ci 0 "the gallery's hosted suites run on each runtime of the matrix" "$CI" --gate 5 --matrix
logged "… on iOS 17.5" "gallery hosted [config=Debug device=ztdsp-ci-17-5 derived=ci-gallery]"
logged "… and on iOS 27.0" "gallery hosted [config=Debug device=ztdsp-ci-27-0 derived=ci-gallery]"
ci 1 "a known issue in the gallery's hosted suites fails gate 5" env STUB_GALLERY_KNOWN=any "$CI" --gate 5
expect_contains "… and says why" "the gallery's hosted suites recorded a known issue: there, none may stand"
expect_contains "… with the test that recorded it" "Test aHostedExpectation() recorded a known issue"
expect_contains "… as a failure of the gate" "$(printf 'ci: gate 5  %-36s FAILED' tests)"
ci 1 "a known issue on one runtime of the matrix fails the gate" env STUB_GALLERY_KNOWN=ztdsp-ci-18-6 "$CI" --gate 5 --matrix
expect_contains "… which is named" "FAILED: the gallery's hosted suites on ztdsp-ci-18-6, with no known issue"
logged "… after the other runtimes ran" "gallery hosted [config=Debug device=ztdsp-ci-27-0 derived=ci-gallery]"

# The nightly job: the gallery's UI tests, which are not a gate.
ci 0 "--nightly runs the gallery's UI tests" "$CI" --nightly
logged "… in Debug, in the gallery's derived data" "gallery ui [config=Debug device= derived=ci-gallery]"
not_logged "… and no gate" "lint-bans"
not_logged "… not even the build" "xcodebuild"
expect_contains "… and reports as the nightly job" "$(printf 'ci: nightly  %-36s passed' "the gallery's UI tests (not a gate)")"
ci 0 "--nightly --matrix runs them on each runtime of the matrix" "$CI" --nightly --matrix
logged "… on iOS 17.5" "gallery ui [config=Debug device=ztdsp-ci-17-5 derived=ci-gallery]"
logged "… and on iOS 27.0" "gallery ui [config=Debug device=ztdsp-ci-27-0 derived=ci-gallery]"
ci 1 "a UI test that fails fails the nightly run" env STUB_GALLERY_UI=1 "$CI" --nightly
expect_contains "… which is reported" "$(printf 'ci: nightly  %-36s FAILED' "the gallery's UI tests (not a gate)")"
ci 1 "… with its own annotation on GitHub" env GITHUB_ACTIONS=true STUB_GALLERY_UI=1 "$CI" --nightly
expect_contains "… that names the nightly job" "::error title=CI nightly job (the gallery's UI tests (not a gate))::"
expect_status 2 "--nightly with a gate is a usage error" "$CI" --nightly --gate 1
expect_status 0 "--list names what each gate runs" "$CI" --list
expect_contains "… gate 1, the gallery application in Release" "the gallery
     application in Release (Examples/ZTronDSPGallery/gallery.sh app"
expect_contains "… gate 5, the gallery's hosted suites" "suites (gallery.sh hosted), which fail on the words \"recorded a known issue\""
expect_contains "… gate 9, the parity suite as part A of brief 61 adapted it" "two known issues may stand: the probe's"
expect_contains "… the second the out-of-place gain at its bound" "and over it in about half the launches (CR-025 item 1)"
expect_contains "… and the nightly job, which is not a gate" "Nightly, not a gate (--nightly): the gallery's UI tests (gallery.sh ui"

ci 0 "without audit tests the Release run is skipped" "$CI" --gate 5
expect_contains "… loudly" "SKIPPED: the Release run of the allocation-audit tests: no test calls expectNoAllocations yet"
printf 'import Testing\n@Test func kernelDoesNotAllocate() { expectNoAllocations { } }\n' > "$S/Tests/ZTronDSPCoreTests/AuditTests.swift"
ci 1 "audit tests that are not listed for the Release run fail the gate" "$CI" --gate 5
expect_contains "… with the file to list them in" "none is listed in Scripts/ci/allocation-audit-filters.txt for the Release run (CR-002)"
printf 'ZTronDSPCoreTests/AuditTests   # the kernels\nCZTronDSPTests\n' >> "$S/Scripts/ci/allocation-audit-filters.txt"
ci 0 "listed audit tests run once more in Release" "$CI" --gate 5
logged "… with testability kept, and only those tests" "xc test ZTronDSPCoreTests/AuditTests CZTronDSPTests [config=Release device= derived=ci xcargs=ENABLE_TESTABILITY=YES]"
ci 1 "a failure of the Release run fails the gate" env STUB_XC_TEST=1 "$CI" --gate 5

ci 0 "--tsan adds the Thread Sanitizer run" "$CI" --gate 5 --tsan
logged "… in a derived-data folder of its own" "xc test [config= device= derived=ci-tsan xcargs=-enableThreadSanitizer YES]"
ci 0 "--tsan-only runs nothing else" "$CI" --gate 5 --tsan-only
not_logged "… no Debug run" "test-only"
not_logged "… and no gallery" "gallery hosted"

expect_status 2 "an unknown gate is a usage error" "$CI" --gate 12
expect_status 2 "an unknown option is a usage error" "$CI" --everything
unset ZTD_CI_XC ZTD_CI_XCODEBUILD ZTD_CI_SIMCTL ZTD_CI_GALLERY STUB_PRODUCTS STUB_ROOT

# ---------------------------------------------------------------------------------------------
# Part 2: the real scripts, on a copy of the package with one violation seeded per gate
# ---------------------------------------------------------------------------------------------
PRODUCTS="$("$ROOT/Scripts/xc.sh" products)"
if [ ! -d "$PRODUCTS/ZTronDSPCore.swiftmodule" ]; then
    echo "  SKIP  seeded violations of the gates: there is no build at $PRODUCTS (run Scripts/xc.sh build)"
    finish; exit $?
fi
export ZTD_DERIVED="$(cd "$PRODUCTS/../../.." && pwd)"     # gates 3 and 4 read the modules of the last build
copy() { reset_folder "$SCRATCH/copy"; rsync -a --exclude .build --exclude .git "$ROOT/" "$SCRATCH/copy/"; }
COPY="$SCRATCH/copy"

copy
expect_status 0 "a clean copy passes gates 2, 3, 4 and 7" "$COPY/Scripts/ci.sh" --gate 2 --gate 3 --gate 4 --gate 7

copy; printf '\nimport UIKit\n' >> "$COPY/Sources/ZTronDSPCore/Placeholder.swift"
expect_status 1 "gate 2: a seeded UIKit import fails" "$COPY/Scripts/ci.sh" --gate 2
expect_contains "… as UB-1" "[UB-1]"

copy; printf '\nimport AVFAudio\n' >> "$COPY/Sources/ZTronDSPCore/Placeholder.swift"
expect_status 1 "gate 2: a seeded import across the dependency graph fails" "$COPY/Scripts/ci.sh" --gate 2
expect_contains "… as DEP-1" "ZTronDSPCore imports AVFAudio (DEP-1"

copy; printf '// expect: this sentence is never printed\nlet fine: Int = 1\n' > "$COPY/Tests/CompileFixtures/invalid/Compiles.swift"
expect_status 1 "gate 3: a seeded fixture that compiles although filed as invalid fails" "$COPY/Scripts/ci.sh" --gate 3
expect_contains "… and is named" "Compiles.swift: it is filed as invalid and compiles"

copy; printf 'swift.func             removed() : func removed()\n' >> "$COPY/Docs/API/ZTronDSPCore.txt"
expect_status 1 "gate 4: a seeded difference between the API and its digest fails" "$COPY/Scripts/ci.sh" --gate 4
expect_contains "… and the module is named" "the public API of ZTronDSPCore differs from its committed digest"

copy; printf '\npublic func seededBare() {}\n' >> "$COPY/Sources/ZTronDSPCore/Placeholder.swift"
expect_status 1 "gate 4: a seeded public declaration without a documentation comment fails" "$COPY/Scripts/ci.sh" --gate 4
expect_contains "… and is named, by the audit of the documentation" "Sources/ZTronDSPCore/Placeholder.swift:"
expect_contains "… as the sources show it" '[source] `public func seededBare() {}`'

# The fixture reports describe the fixture tree, so the copy gets that tree's sources: the
# gate reads coverage:ignore marks, and which targets hold code, from the tree it stands in.
copy; rm -rf "$COPY/Sources"; cp -R "$ROOT/Tests/Fixtures/Coverage/tree/Sources" "$COPY/Sources"
expect_status 0 "gate 6: a coverage report above the thresholds passes" \
    env ZTD_CI_COVERAGE_REPORT="$ROOT/Tests/Fixtures/Coverage/report-pass.json $ROOT/Tests/Fixtures/Coverage/lines-pass.json" "$COPY/Scripts/ci.sh" --gate 6
expect_status 1 "gate 6: a seeded coverage report below the threshold fails" env ZTD_CI_COVERAGE_REPORT="$ROOT/Tests/Fixtures/Coverage/report-fail-aggregate.json" "$COPY/Scripts/ci.sh" --gate 6
expect_contains "… with the number" "aggregate coverage is 96.00 %, below 97.50 %"

copy; sed -i '' 's/-1.0/-1.5/' "$COPY/Tests/ZTronDSPDesignTests/Golden/buttap.json"
expect_status 1 "gate 7: a seeded change of a golden vector fails" "$COPY/Scripts/ci.sh" --gate 7
expect_contains "… and the vector is named" "buttap.json is not the file the manifest recorded"

# Gates 8 and 9 never run their real scripts here. Those run suites on a simulator for minutes,
# and with ZTD_DERIVED exported they would build the copy into the derived data of the tree this
# test was started from, whose module maps would then name a folder that no longer exists: the
# next Scripts/api-digest.sh --check there would fail. Each script is absent, or a stand-in.
copy; rm -f "$COPY/Scripts/benchmarks.sh" "$COPY/Scripts/external-parity.sh"
expect_status 0 "gates 8 and 9 without their scripts are skipped" "$COPY/Scripts/ci.sh" --gate 8 --gate 9
expect_contains "… loudly" "ci: gate 8  benchmarks                           SKIPPED"
expect_contains "… both of them" "Scripts/external-parity.sh does not exist yet"
printf '#!/bin/bash\necho "benchmarks: there is no baseline: nothing is compared"\nexit 3\n' > "$COPY/Scripts/benchmarks.sh"; chmod +x "$COPY/Scripts/benchmarks.sh"
expect_status 0 "gate 8: a run that compared nothing is skipped, not passed" "$COPY/Scripts/ci.sh" --gate 8
expect_contains "… and says that nothing was compared" "there is no baseline for this runner"
printf '#!/bin/bash\necho "benchmark regression: gain kernel 14 %% slower than its baseline"\nexit 1\n' > "$COPY/Scripts/benchmarks.sh"; chmod +x "$COPY/Scripts/benchmarks.sh"
expect_status 1 "gate 8: a seeded regression fails once the check exists" "$COPY/Scripts/ci.sh" --gate 8
printf '#!/bin/bash\necho "external parity: the gain written outside the package differs from its stock twin"\nexit 1\n' > "$COPY/Scripts/external-parity.sh"; chmod +x "$COPY/Scripts/external-parity.sh"
expect_status 1 "gate 9: a parity suite that fails fails the gate" "$COPY/Scripts/ci.sh" --gate 9
MAPS="$ZTD_DERIVED/Build/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator"
if grep -q -s -F "$SCRATCH" "$MAPS"/*.modulemap; then
    fail "the derived data this test read is left as it was found" "a module map under $MAPS names the scratch folder $SCRATCH"
else
    pass "the derived data this test read is left as it was found"
fi

if [ "$SLOW" -eq 1 ]; then
    unset ZTD_DERIVED
    copy
    expect_status 0 "gate 1 (real build): a clean copy builds for simulator and device with warnings as errors" "$COPY/Scripts/ci.sh" --gate 1
    printf '\nfunc seededWarning() {\n    let unused = 1\n}\n' >> "$COPY/Sources/ZTronDSPCore/Placeholder.swift"
    expect_status 1 "gate 1 (real build): a seeded compiler warning in a production target fails" "$COPY/Scripts/ci.sh" --gate 1
    expect_contains "… as an error" "error: initialization of immutable value 'unused' was never used"
    copy
    printf '\n#warning "a seeded warning of the Metal compiler"\n' >> "$COPY/Sources/ZTronDSPMetal/Shaders/Common.metal"
    expect_status 1 "gate 1 (real build): a seeded warning of the Metal compiler fails (DEP-4: the build compiles the shaders)" "$COPY/Scripts/ci.sh" --gate 1
    expect_contains "… as an error" 'error: "a seeded warning of the Metal compiler" [-Werror,-W#warnings]'
else
    echo "  SKIP  gate 1 with a real build and a seeded warning (run this test with --slow)"
fi
echo "  NOTE  gate 5 was exercised through its stand-in only: this self-test runs no simulator test"
finish
