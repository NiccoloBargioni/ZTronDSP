#!/bin/bash
# The continuous-integration gates of §10.3, in order, runnable locally (WP-014).
# .github/workflows/ci.yml runs the same gates through this script.
#
#   Scripts/ci.sh                       every gate, in order; stops at the first that fails
#   Scripts/ci.sh --gate N [--gate M]   the named gates, in order
#   Scripts/ci.sh --list                what each gate runs
#   Scripts/ci.sh --keep-going          run the remaining gates after a failure
#   Scripts/ci.sh --strict              a gate, or a part of one, that was skipped fails the run
#   Scripts/ci.sh --nightly             no gate: the nightly job, the gallery's UI tests (with
#                                       --runtime or --matrix, on each of those simulators)
#
# Gate 5 (tests), and the nightly job:
#   --runtime ID      run on this simulator runtime, e.g. com.apple.CoreSimulator.SimRuntime.iOS-17-5
#                     (repeatable); without it the tests run on the device of Scripts/xc.sh
#   --matrix          run on every runtime of PLAT-3 that is installed: iOS 17.5, the newest
#                     18.x, the newest 26.x, 27.0
#   --tsan            also run the tests under the Thread Sanitizer
#   --tsan-only       run only the Thread Sanitizer part of gate 5
#
# The gates:
#   1  Build for simulator and device, warnings as errors in the production targets; the gallery
#      application in Release (Examples/ZTronDSPGallery/gallery.sh app, derived data of its own)
#   2  Scripts/lint-bans.sh, all four parts; Scripts/check-dependency-graph.sh (DEP-1…DEP-3)
#   3  Scripts/compile-fixtures.sh and the order matrix (Scripts/order-matrix.sh --check, WP-328)
#   4  Scripts/api-digest.sh --check
#   5  Tests in Debug on the simulator matrix, and on each of its simulators the gallery's hosted
#      suites (gallery.sh hosted), which fail on the words "recorded a known issue"; the
#      allocation-audit tests once more in Release (CR-002); the Thread Sanitizer run
#   6  Scripts/coverage-gate.sh on the result of gate 5
#   7  Scripts/golden.sh --check
#   8  The benchmark regression check (Scripts/benchmarks.sh --check, WP-006), on a pinned runner
#   9  The external parity suite (Scripts/external-parity.sh, WP-907): the promises of EXT-1…EXT-4
#      held as plain expectations (values that update without a plan, a node audited on the
#      test's thread, the guide made from its template); two known issues may stand: the probe's
#      control case, and in the speed check the out-of-place gain, which is at 5 % of its twin
#      and over it in about half the launches (CR-025 item 1)
#   Nightly, not a gate (--nightly): the gallery's UI tests (gallery.sh ui, 6 to 14 minutes)
#
# A gate whose input does not exist yet is reported as SKIPPED, loudly, with what is missing;
# it never passes silently. Under --strict a skip is a failure.
#
# Environment:
#   ZTD_DERIVED              derived data of the CI builds (default <package>/.build/ci), kept apart
#                            from the one Scripts/xc.sh uses by default, because the CI builds carry
#                            coverage instrumentation; the gallery builds into <ZTD_DERIVED>-gallery
#                            (its tests) and <ZTD_DERIVED>-gallery-release (the application)
#   ZTD_DEVICE               the simulator of gate 5 when no runtime is named (see Scripts/xc.sh)
#   ZTD_CI_CHANGED_FILES     a file listing changed files, one per line: gate 6 then also checks COV-3
#   ZTD_CI_BASE_REF          a git ref: the changed files are those that differ from it
#   ZTD_CI_COVERAGE_REPORT   xccov JSON report(s) for gate 6, instead of the result bundle of gate 5
#   ZTD_CI_XC, ZTD_CI_XCODEBUILD, ZTD_CI_SIMCTL, ZTD_CI_GALLERY
#                            stand-ins for Scripts/xc.sh, xcodebuild, `xcrun simctl` and
#                            Examples/ZTronDSPGallery/gallery.sh (the self-test)
#
# Exit status: 0 no gate failed, 1 a gate failed (or was skipped under --strict), 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

XC="${ZTD_CI_XC:-$ROOT/Scripts/xc.sh}"
XCODEBUILD="${ZTD_CI_XCODEBUILD:-xcodebuild}"
SIMCTL="${ZTD_CI_SIMCTL:-xcrun simctl}"
GALLERY="${ZTD_CI_GALLERY:-$ROOT/Examples/ZTronDSPGallery/gallery.sh}"
DERIVED="${ZTD_DERIVED:-$ROOT/.build/ci}"
export ZTD_DERIVED="$DERIVED"
RESULTS=".build/ci-results"                 # relative to the package: Scripts/xc.sh splits ZTD_XCARGS on spaces
AUDIT_FILTERS="$ROOT/Scripts/ci/allocation-audit-filters.txt"
PRODUCTION_SCHEMES="ZTronDSP ZTronDSPUI"

# Number 0 is not a gate: the nightly job, which the loop below runs as it runs a gate.
GATE_NAMES=("the gallery's UI tests (not a gate)" "build" "lint and dependency graph" "compile fixtures and order matrix" "API digest" "tests" "coverage" "golden vectors" "benchmarks" "external parity")

gates=(); keep_going=0; strict=0; runtimes=(); matrix=0; tsan=0; tsan_only=0; nightly=0
while [ $# -gt 0 ]; do
    case "$1" in
        --gate)
            [ $# -ge 2 ] || { echo "ci: --gate takes a number" >&2; exit 2; }
            case "$2" in [1-9]) gates+=("$2") ;; *) echo "ci: there is no gate $2" >&2; exit 2 ;; esac
            shift ;;
        --runtime)
            [ $# -ge 2 ] || { echo "ci: --runtime takes a runtime identifier" >&2; exit 2; }
            runtimes+=("$2"); shift ;;
        --matrix) matrix=1 ;;
        --tsan) tsan=1 ;;
        --tsan-only) tsan_only=1 ;;
        --nightly) nightly=1 ;;
        --keep-going) keep_going=1 ;;
        --strict) strict=1 ;;
        --list) awk '/^# The gates:/ { on = 1 } on && /^#$/ { exit } on { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "ci: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$nightly" -eq 1 ] && [ "${#gates[@]}" -gt 0 ]; then
    echo "ci: --nightly runs the job that is not a gate, alone; it takes no --gate" >&2; exit 2
fi
if [ "${#gates[@]}" -eq 0 ]; then gates=(1 2 3 4 5 6 7 8 9); fi
# In order, each once.
ordered=()
for number in 1 2 3 4 5 6 7 8 9; do
    for wanted in "${gates[@]}"; do
        if [ "$wanted" = "$number" ]; then ordered+=("$number"); break; fi
    done
done
[ "$nightly" -eq 1 ] && ordered=(0)

# ---------------------------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------------------------
RESULT=(); NOTE=()
part_pass=0; part_fail=0; part_skip=0; gate_notes=""; current=0

label() { if [ "$1" = 0 ]; then printf 'nightly'; else printf 'gate %s' "$1"; fi; }
title() { if [ "$current" = 0 ]; then printf 'CI nightly job (%s)' "${GATE_NAMES[0]}"; else printf 'CI gate %s (%s)' "$current" "${GATE_NAMES[$current]}"; fi; }

say() { printf 'ci: [%s] %s\n' "$(label "$current")" "$*"; }

ok() { part_pass=$((part_pass + 1)); say "ok: $*"; }

failed() {
    part_fail=$((part_fail + 1))
    say "FAILED: $*"
    gate_notes="${gate_notes:+$gate_notes; }$*"
    [ "${GITHUB_ACTIONS:-}" = "true" ] && printf '::error title=%s::%s\n' "$(title)" "$*"
    return 0
}

skipped() {
    part_skip=$((part_skip + 1))
    say "SKIPPED: $*"
    gate_notes="${gate_notes:+$gate_notes; }skipped: $*"
    [ "${GITHUB_ACTIONS:-}" = "true" ] && printf '::warning title=%s skipped::%s\n' "$(title)" "$*"
    return 0
}

# run <what it is> <command …>: runs the command with its output shown; records ok or FAILED.
run() {
    local what="$1"; shift
    say "$what"
    if "$@"; then ok "$what"; return 0; fi
    failed "$what"
    return 1
}

# xcodebuild finds the package in the directory it is run from.
in_package() { ( cd "$ROOT" && "$@" ); }

ensure_build() {
    local products
    products="$("$XC" products)"
    if [ ! -d "$products/ZTronDSPCore.swiftmodule" ]; then
        say "no build yet under $DERIVED: building"
        ZTD_XCARGS="-enableCodeCoverage YES" "$XC" build
    fi
}

# ---------------------------------------------------------------------------------------------
# Simulators of the matrix (PLAT-3)
# ---------------------------------------------------------------------------------------------
matrix_runtimes() {   # prints the identifiers of the installed runtimes PLAT-3 names
    $SIMCTL list runtimes -j | python3 -c '
import json, sys
installed = {}
for runtime in json.load(sys.stdin).get("runtimes", []):
    identifier = runtime.get("identifier", "")
    if runtime.get("isAvailable") and identifier.startswith("com.apple.CoreSimulator.SimRuntime.iOS-"):
        version = tuple(int(part) for part in identifier.rsplit("iOS-", 1)[1].split("-"))
        installed[version] = identifier
def newest(major):
    versions = sorted(v for v in installed if v[0] == major)
    return installed[versions[-1]] if versions else "missing:iOS %d.x" % major
print(installed.get((17, 5), "missing:iOS 17.5"))
print(newest(18))
print(newest(26))
print(installed.get((27, 0), "missing:iOS 27.0"))
'
}

# simulators: sets `devices` (the caller's) to the simulators that tests run on: one per runtime
# that --runtime names or --matrix finds, made when need be; without either, one empty name, which
# is the device of Scripts/xc.sh and of gallery.sh.
simulators() {
    local wanted=(${runtimes[@]+"${runtimes[@]}"}) runtime name
    devices=()
    if [ "$matrix" -eq 1 ]; then
        while IFS= read -r runtime; do
            case "$runtime" in
                missing:*) skipped "the ${runtime#missing:} simulator runtime of PLAT-3 is not installed" ;;
                ?*) wanted+=("$runtime") ;;
            esac
        done <<EOF_RUNTIMES
$(matrix_runtimes)
EOF_RUNTIMES
    fi
    if [ "${#wanted[@]}" -eq 0 ]; then
        devices=("${ZTD_DEVICE:-}")
    else
        for runtime in "${wanted[@]}"; do
            if name="$(ensure_simulator "$runtime")"; then devices+=("$name"); else failed "no simulator could be made for the runtime $runtime"; fi
        done
    fi
}

# gallery_hosted <simulator, or empty for the default one>: the gallery's hosted suites
# (GalleryTests) on it, in Debug, in derived data of their own. They have no expectation that
# may fail: a run that "recorded a known issue" fails as one that recorded an issue does.
gallery_hosted() {
    local log status
    log="$(mktemp "${TMPDIR:-/tmp}/ztd-ci-gallery.XXXXXX")" || return 1
    env ZTD_DEVICE="$1" ZTD_CONFIG=Debug ZTD_DERIVED="$DERIVED-gallery" "$GALLERY" hosted 2>&1 | tee "$log"
    status="${PIPESTATUS[0]}"
    if [ "$status" -eq 0 ] && grep -q "recorded a known issue" "$log"; then
        say "the gallery's hosted suites recorded a known issue: there, none may stand"
        status=1
    fi
    rm -f "$log"
    return "$status"
}

ensure_simulator() {  # <runtime identifier>: prints the name of a simulator on that runtime, creating it if needed
    local runtime="$1" name type
    name="ztdsp-ci-${runtime##*iOS-}"
    if ! $SIMCTL list devices available | grep -q -E "^ +${name} \("; then
        type="$($SIMCTL list runtimes -j | python3 -c '
import json, sys
wanted = sys.argv[1]
for runtime in json.load(sys.stdin).get("runtimes", []):
    if runtime.get("identifier") == wanted:
        phones = [t["identifier"] for t in runtime.get("supportedDeviceTypes", []) if t.get("productFamily") == "iPhone"]
        print(phones[0] if phones else "")
' "$runtime")"
        [ -n "$type" ] || return 1
        $SIMCTL create "$name" "$type" "$runtime" >/dev/null || return 1
    fi
    printf '%s\n' "$name"
}

# ---------------------------------------------------------------------------------------------
# The gates
# ---------------------------------------------------------------------------------------------
gate_1() {
    local udid scheme
    udid="$("$XC" device)" || { failed "no simulator to build for"; return; }
    for scheme in $PRODUCTION_SCHEMES; do
        run "build $scheme for the simulator, warnings as errors" \
            in_package "$XCODEBUILD" build -scheme "$scheme" -destination "platform=iOS Simulator,id=$udid" -derivedDataPath "$DERIVED-strict" \
            -quiet SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES || return
        run "build $scheme for a device, warnings as errors" \
            in_package "$XCODEBUILD" build -scheme "$scheme" -destination "generic/platform=iOS" -derivedDataPath "$DERIVED-strict" \
            -quiet SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES CODE_SIGNING_ALLOWED=NO || return
    done
    run "build the gallery application in Release, in derived data of its own" \
        env ZTD_CONFIG=Release ZTD_DERIVED="$DERIVED-gallery-release" "$GALLERY" app || return
    run "build everything for testing (Debug, coverage on)" env ZTD_XCARGS="-enableCodeCoverage YES" "$XC" build
}

gate_2() {
    run "lint-bans, parts 1 to 4" "$ROOT/Scripts/lint-bans.sh"
    run "the dependency graph equals §4.2" "$ROOT/Scripts/check-dependency-graph.sh"
}

gate_3() {
    ensure_build || { failed "the build that the fixtures are type-checked against"; return; }
    say "compile fixtures"
    "$ROOT/Scripts/compile-fixtures.sh"
    case $? in
        0) ok "compile fixtures" ;;
        3) skipped "there is no compile fixture under Tests/CompileFixtures" ;;
        *) failed "compile fixtures" ;;
    esac
    if [ -x "$ROOT/Scripts/order-matrix.sh" ]; then
        run "the order matrix: tier 1 and tier 2 agree (ORD-2)" "$ROOT/Scripts/order-matrix.sh" --check
    else
        skipped "the order matrix: Scripts/order-matrix.sh does not exist yet (WP-328)"
    fi
}

gate_4() {
    ensure_build || { failed "the build whose public API is compared"; return; }
    run "the API digest equals the build; stage initialisers; public references only" "$ROOT/Scripts/api-digest.sh" --check
}

gate_5() {
    local bundle="$RESULTS/Debug.xcresult" devices=() name first=1 arguments filters=() line
    if [ "$tsan_only" -eq 0 ]; then
        run "build everything for testing (Debug, coverage on)" env ZTD_XCARGS="-enableCodeCoverage YES" "$XC" build || return

        simulators
        mkdir -p "$ROOT/$RESULTS"
        for name in ${devices[@]+"${devices[@]}"}; do
            arguments="-enableCodeCoverage YES"
            if [ "$first" -eq 1 ]; then
                rm -rf "${ROOT:?}/$bundle"
                arguments="$arguments -resultBundlePath $bundle"
                first=0
            fi
            if [ -n "$name" ]; then
                run "tests in Debug on $name" env ZTD_DEVICE="$name" ZTD_CONFIG=Debug ZTD_XCARGS="$arguments" "$XC" test-only
            else
                run "tests in Debug" env ZTD_CONFIG=Debug ZTD_XCARGS="$arguments" "$XC" test-only
            fi
            run "the gallery's hosted suites${name:+ on $name}, with no known issue" gallery_hosted "$name"
        done

        # CR-002: a Debug run shows that the hot path does not allocate at -Onone; the same tests
        # in Release show it for the code that ships.
        if [ -f "$AUDIT_FILTERS" ]; then
            while IFS= read -r line; do
                line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
                [ -n "$line" ] && filters+=("$line")
            done < "$AUDIT_FILTERS"
        fi
        if [ "${#filters[@]}" -gt 0 ]; then
            run "the allocation-audit tests in Release (${#filters[@]} filter(s))" \
                env ZTD_CONFIG=Release ZTD_XCARGS="ENABLE_TESTABILITY=YES" "$XC" test "${filters[@]}"
        elif grep -r -q -E "expectNoAllocations" "$ROOT/Tests" --include='*.swift' --exclude-dir=Fixtures --exclude-dir=CompileFixtures 2>/dev/null; then
            failed "tests call expectNoAllocations, and none is listed in Scripts/ci/allocation-audit-filters.txt for the Release run (CR-002)"
        else
            skipped "the Release run of the allocation-audit tests: no test calls expectNoAllocations yet"
        fi
    fi
    if [ "$tsan" -eq 1 ] || [ "$tsan_only" -eq 1 ]; then
        run "tests under the Thread Sanitizer" env ZTD_DERIVED="$DERIVED-tsan" ZTD_XCARGS="-enableThreadSanitizer YES" "$XC" test
    fi
}

gate_6() {
    local arguments=() report status list=""
    if [ -n "${ZTD_CI_COVERAGE_REPORT:-}" ]; then
        for report in $ZTD_CI_COVERAGE_REPORT; do arguments+=(--report "$report"); done
    elif [ -d "$ROOT/$RESULTS/Debug.xcresult" ]; then
        arguments=(--xcresult "$ROOT/$RESULTS/Debug.xcresult")
    else
        skipped "there is no result bundle at $RESULTS/Debug.xcresult: run gate 5 first"
        return
    fi
    say "coverage: aggregate and per target (COV-2)"
    "$ROOT/Scripts/coverage-gate.sh" "${arguments[@]}" --mode aggregate --mode per-target
    status=$?
    case $status in
        0) ok "coverage: aggregate and per target" ;;
        3) skipped "coverage: the report holds no executable line of a production target yet"; return ;;
        *) failed "coverage: aggregate and per target" ;;
    esac

    if [ -n "${ZTD_CI_CHANGED_FILES:-}" ]; then
        list="$ZTD_CI_CHANGED_FILES"
    elif [ -n "${ZTD_CI_BASE_REF:-}" ] && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        list="$(mktemp "${TMPDIR:-/tmp}/ztd-ci-changed.XXXXXX")" || { failed "no scratch file for the list of changed files"; return; }
        git -C "$ROOT" diff --name-only --diff-filter=AMR "$ZTD_CI_BASE_REF"...HEAD -- Sources > "$list" || { failed "the files changed since $ZTD_CI_BASE_REF could not be listed"; return; }
    fi
    if [ -n "$list" ]; then
        if [ -s "$list" ]; then
            say "coverage: the changed files (COV-3)"
            if "$ROOT/Scripts/coverage-gate.sh" "${arguments[@]}" --mode changed-files < "$list"; then ok "coverage: the changed files"; else failed "coverage: the changed files"; fi
        else
            say "coverage: no changed file to check against COV-3"
        fi
    else
        say "coverage: COV-3 was not checked (no list of changed files: set ZTD_CI_CHANGED_FILES or ZTD_CI_BASE_REF)"
    fi
}

gate_7() {
    local status
    say "golden vectors against their manifest"
    if [ "$strict" -eq 1 ]; then "$ROOT/Scripts/golden.sh" --check --strict; else "$ROOT/Scripts/golden.sh" --check; fi
    status=$?
    case $status in
        0) ok "golden vectors against their manifest" ;;
        3) failed "golden vectors: generators are still pending" ;;
        *) failed "golden vectors against their manifest" ;;
    esac
}

gate_8() {
    local status
    if [ -x "$ROOT/Scripts/benchmarks.sh" ]; then
        say "benchmarks against their committed baselines (a regression above 10 % fails)"
        "$ROOT/Scripts/benchmarks.sh" --check
        status=$?
        case $status in
            0) ok "benchmarks against their committed baselines" ;;
            3) skipped "the benchmark regression check: there is no baseline for this runner (the budgets of §5.7 were held; nothing was compared)" ;;
            *) failed "benchmarks against their committed baselines" ;;
        esac
    else
        skipped "the benchmark regression check: Scripts/benchmarks.sh does not exist yet (WP-006 delivers the harness and the baselines)"
    fi
}

# Not a gate: the gallery's UI tests take 6 to 14 minutes, so they run nightly
# (.github/workflows/ci.yml), on each simulator gate 5 would use.
nightly_job() {
    local devices=() name
    simulators
    for name in ${devices[@]+"${devices[@]}"}; do
        run "the gallery's UI tests${name:+ on $name}" env ZTD_DEVICE="$name" ZTD_CONFIG=Debug ZTD_DERIVED="$DERIVED-gallery" "$GALLERY" ui
    done
}

gate_9() {
    if [ -x "$ROOT/Scripts/external-parity.sh" ]; then
        run "the external parity suite (EXT-4)" "$ROOT/Scripts/external-parity.sh"
    else
        skipped "the external parity suite: Scripts/external-parity.sh does not exist yet (WP-907)"
    fi
}

# ---------------------------------------------------------------------------------------------

overall=0
for current in "${ordered[@]}"; do
    part_pass=0; part_fail=0; part_skip=0; gate_notes=""
    printf '\nci: ===== %s: %s =====\n' "$(label "$current")" "${GATE_NAMES[$current]}"
    if [ "$current" = 0 ]; then nightly_job; else "gate_$current"; fi
    if [ "$part_fail" -gt 0 ]; then
        RESULT[$current]="FAILED"
    elif [ "$part_skip" -gt 0 ] && [ "$part_pass" -eq 0 ]; then
        RESULT[$current]="SKIPPED"
    elif [ "$part_skip" -gt 0 ]; then
        RESULT[$current]="PASSED IN PART"
    else
        RESULT[$current]="passed"
    fi
    NOTE[$current]="$gate_notes"
    if [ "${RESULT[$current]}" = "FAILED" ]; then
        overall=1
        [ "$keep_going" -eq 1 ] || break
    elif [ "$strict" -eq 1 ] && [ "${RESULT[$current]}" != "passed" ]; then
        overall=1
        [ "$keep_going" -eq 1 ] || break
    fi
done

printf '\nci: ===== summary =====\n'
for number in "${ordered[@]}"; do
    if [ -z "${RESULT[$number]:-}" ]; then
        printf 'ci: %s  %-36s not run\n' "$(label "$number")" "${GATE_NAMES[$number]}"
    else
        printf 'ci: %s  %-36s %s%s\n' "$(label "$number")" "${GATE_NAMES[$number]}" "${RESULT[$number]}" "${NOTE[$number]:+ — ${NOTE[$number]}}"
    fi
done
if [ "$overall" -ne 0 ]; then
    [ "$strict" -eq 1 ] && echo "ci: --strict: a skipped gate counts as a failure"
    echo "ci: FAILED"
else
    echo "ci: no gate failed"
fi
exit $overall
