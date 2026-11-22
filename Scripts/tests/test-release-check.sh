#!/bin/bash
# Self-test of Scripts/release-check.sh (WP-906).
#
# Runs release-check.sh in a scratch tree among stand-ins: the real Scripts/ci.sh among
# stand-ins for every tool it calls (as Scripts/tests/test-ci.sh has them), stand-ins for the
# scripts the checklist runs beside the gates, and for git and df. Each case seeds one state (a
# gate that fails, a skip that is the owner's, a runtime that is not installed, a ledger row that
# is not Done, a change request still Proposed, a tree that differs from HEAD, a full disk) and
# reads the result line of the items it concerns. The last part holds the checklist,
# Docs/Release/0.1.0-checklist.md, to the script: the same items, in the same order, with the
# same commands. No simulator is used and nothing is built.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
make_scratch release-check-test

echo "release-check"

S="$SCRATCH/tree"
mkdir -p "$S/Scripts/ci" "$S/Scripts/tests" "$S/Docs/Process/changes" "$S/Docs/Numerics" "$S/products/ZTronDSPCore.swiftmodule" "$S/bin" "$S/state" "$S/logs"
export STUB_LOG="$S/log" STUB_STATE="$S/state"
HEAD1="1111111111111111111111111111111111111111"
HEAD2="2222222222222222222222222222222222222222"
OTHER="3333333333333333333333333333333333333333"

# standin <path> <name in the log>: logs its call, prints a last line, and exits with
# $STUB_<NAME>_<FIRST ARGUMENT> when that is set (STUB_LINT_BANS_PART for `lint-bans.sh --part 3`),
# else with $STUB_<NAME>, else 0.
standin() {
    { printf '#!/bin/bash\nNAME=%s\n' "$2"; cat <<'EOS'; } > "$1"
VARIABLE="STUB_$(printf '%s' "$NAME" | tr 'a-z-' 'A-Z_')"
echo "$NAME $*" >> "$STUB_LOG"
first="$(printf '%s' "${1:-}" | sed 's/^--//' | tr 'a-z-' 'A-Z_' | tr -cd 'A-Z0-9_')"
status=""
[ -n "$first" ] && eval "status=\"\${${VARIABLE}_${first}:-}\""
[ -n "$status" ] || eval "status=\"\${${VARIABLE}:-0}\""
echo "$NAME${*:+ $*}: done (stand-in, exit $status)"
exit "$status"
EOS
    chmod +x "$1"
}

# The tools of Scripts/ci.sh, as Scripts/tests/test-ci.sh has them.
cat > "$S/bin/xc" <<'EOS'
#!/bin/bash
echo "xc $* [config=${ZTD_CONFIG:-} device=${ZTD_DEVICE:-} derived=${ZTD_DERIVED##*/} xcargs=${ZTD_XCARGS:-}]" >> "$STUB_LOG"
case "${1:-}" in
    products) echo "$STUB_PRODUCTS" ;;
    device) echo "FAKE-UDID" ;;
    build) exit "${STUB_XC_BUILD:-0}" ;;
    test-only)
        bundle="$(printf '%s' "${ZTD_XCARGS:-}" | sed -n -E 's/.*-resultBundlePath ([^ ]+).*/\1/p')"
        [ -n "$bundle" ] && mkdir -p "$STUB_ROOT/$bundle"
        [ "${ZTD_DEVICE:-}" = "${STUB_XC_FAILING_DEVICE:-none}" ] && exit 1
        exit "${STUB_XC_TEST_ONLY:-0}" ;;
    test) exit "${STUB_XC_TEST:-0}" ;;
esac
EOS
cat > "$S/bin/xcodebuild" <<'EOS'
#!/bin/bash
echo "xcodebuild $*" >> "$STUB_LOG"
exit "${STUB_XCODEBUILD:-0}"
EOS
# The runtimes of PLAT-3, all installed (two of 18.x: the newest is the one that runs), less
# those whose major version STUB_SIMCTL_WITHOUT names. No simulator exists before the run: each is
# made, unless STUB_SIMCTL_CREATE says making one fails.
cat > "$S/bin/simctl" <<'EOS'
#!/bin/bash
echo "simctl $*" >> "$STUB_LOG"
runtime() {
    case " ${STUB_SIMCTL_WITHOUT:-} " in *" ${1%%-*} "*) return ;; esac
    printf ' {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-%s", "isAvailable": true, "supportedDeviceTypes": [{"identifier": "com.apple.CoreSimulator.SimDeviceType.%s", "productFamily": "iPhone"}]},\n' "$1" "$2"
}
if [ "$1 $2 ${3:-}" = "list runtimes -j" ]; then
    echo '{"runtimes": ['
    runtime 17-5 iPhone-15-Pro
    runtime 18-4 iPhone-16-Pro
    runtime 18-6 iPhone-16-Pro
    runtime 26-5 iPhone-17-Pro
    runtime 27-0 iPhone-18-Pro
    echo ' {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-16-0", "isAvailable": false, "supportedDeviceTypes": []}'
    echo ']}'
elif [ "$1" = "create" ]; then
    [ "${STUB_SIMCTL_CREATE:-0}" = 0 ] || exit 1
    echo "11111111-1111-1111-1111-111111111111"
fi
EOS
cat > "$S/bin/gallery" <<'EOS'
#!/bin/bash
echo "gallery $* [config=${ZTD_CONFIG:-} device=${ZTD_DEVICE:-} derived=${ZTD_DERIVED##*/}]" >> "$STUB_LOG"
case "${1:-}" in
    app) exit "${STUB_GALLERY_APP:-0}" ;;
    hosted)
        if [ "${STUB_GALLERY_KNOWN:-none}" = "${ZTD_DEVICE:-}" ]; then
            echo "◇ Test aHostedExpectation() recorded a known issue at Hosted.swift:9:9: Expectation failed"
            echo "✔ Test run with 24 tests in 8 suites passed after 9.000 seconds with 1 known issue."
        else
            echo "✔ Test run with 24 tests in 8 suites passed after 9.000 seconds."
        fi
        exit "${STUB_GALLERY_HOSTED:-0}" ;;
    ui) exit "${STUB_GALLERY_UI:-0}" ;;
esac
EOS
# git: HEAD is $STUB_GIT_HEAD1 at the start, and $STUB_GIT_HEAD_LATER (if set) when asked again;
# the status is $STUB_GIT_STATUS_START at the start, $STUB_GIT_STATUS_LATER (if set) at the end;
# the tag names $STUB_GIT_TAG; STUB_GIT_NO_REPO: there is no repository.
cat > "$S/bin/git" <<'EOS'
#!/bin/bash
echo "git $*" >> "$STUB_LOG"
[ "${1:-}" = "-C" ] && shift 2
calls() { echo x >> "$STUB_STATE/$1"; grep -c . "$STUB_STATE/$1"; }
if [ -n "${STUB_GIT_NO_REPO:-}" ]; then echo "fatal: not a git repository (or any of the parent directories): .git" >&2; exit 128; fi
case "$*" in
    "rev-parse HEAD")
        if [ "$(calls head)" -gt 1 ] && [ -n "${STUB_GIT_HEAD_LATER:-}" ]; then echo "$STUB_GIT_HEAD_LATER"; else echo "$STUB_GIT_HEAD1"; fi ;;
    "status --porcelain")
        if [ "$(calls status)" -gt 1 ] && [ -n "${STUB_GIT_STATUS_LATER:-}" ]; then text="$STUB_GIT_STATUS_LATER"; else text="${STUB_GIT_STATUS_START:-}"; fi
        if [ -n "$text" ]; then printf '%s\n' "$text"; fi ;;
    "rev-parse -q --verify refs/tags/"*)
        [ -n "${STUB_GIT_TAG:-}" ] || exit 1
        echo "$STUB_GIT_TAG" ;;
    *) echo "git stand-in: no answer for: $*" >&2; exit 1 ;;
esac
exit 0
EOS
cat > "$S/bin/df" <<'EOS'
#!/bin/bash
echo "df $*" >> "$STUB_LOG"
echo "Filesystem 1G-blocks Used Available Capacity iused ifree %iused Mounted on"
echo "/dev/disk3s5 926 834 ${STUB_DF_FREE:-64} 93% 8759637 676408680 1% /System/Volumes/Data"
EOS
chmod +x "$S/bin/xc" "$S/bin/xcodebuild" "$S/bin/simctl" "$S/bin/gallery" "$S/bin/git" "$S/bin/df"

# The scripts the checklist runs beside the gates, where the generic stand-in will not do.
cat > "$S/Scripts/golden.sh" <<'EOS'
#!/bin/bash
echo "golden $*" >> "$STUB_LOG"
case " $* " in
    *" --octave "*) exit "${STUB_GOLDEN_OCTAVE:-0}" ;;
    *" --reproduce "*)
        echo "golden: butterworth reproduces its committed files bit for bit"
        echo "golden: mel reproduces its committed vectors within 3.1e-15 of each array's largest value (not bit for bit)"
        if [ -n "${STUB_GOLDEN_SKIPPED:-}" ]; then echo "golden: SKIPPED tempogram: librosa is not installed; nothing was reproduced"; fi
        if [ "${STUB_GOLDEN_REPRODUCE:-0}" != 0 ]; then echo "golden: FAILED windows does not reproduce its committed files:"; echo "golden:   windows/hann.json: 3 values differ"; fi
        exit "${STUB_GOLDEN_REPRODUCE:-0}" ;;
esac
exit "${STUB_GOLDEN:-0}"
EOS
cat > "$S/Scripts/spec-crosscheck.sh" <<'EOS'
#!/bin/bash
echo "spec-crosscheck $*" >> "$STUB_LOG"
echo "Read 289 packages in 286 rows, 53 of them ALG, 3 OPT."
echo
echo "DEFECTS (${STUB_SPEC_CROSSCHECK:-0})"
echo
echo "NOTES (2) — readings the check had to choose, not defects"
echo "  [reference] line 2200 names WP-902b: WP-902b is a part of WP-902 that §12 does not define"
exit "${STUB_SPEC_CROSSCHECK:-0}"
EOS
cat > "$S/Scripts/tests/run-all.sh" <<'EOS'
#!/bin/bash
echo "run-all $*" >> "$STUB_LOG"
if [ -n "${STUB_RUN_ALL_SKIP:-}" ]; then echo "  SKIP  $STUB_RUN_ALL_SKIP"; fi
if [ "${STUB_RUN_ALL:-0}" != 0 ]; then echo "run-all: FAILED: ci (1 of 500 checks failed)"; exit "$STUB_RUN_ALL"; fi
echo "run-all: every self-test passed (500 checks in 17 suites${STUB_RUN_ALL_SKIP:+, 1 skipped: see above})"
EOS
# The ledger: --release prints the listing in the file $STUB_LEDGER_LISTING (exit 1, or
# $STUB_LEDGER_RELEASE), or with $STUB_LEDGER_RELEASE alone finds no ledger; otherwise every
# package is Done.
cat > "$S/Scripts/ledger.sh" <<'EOS'
#!/bin/bash
echo "ledger $*" >> "$STUB_LOG"
case "${1:-}" in
    --check) echo "ledger: 293 rows, consistent with §12 and §11"; exit "${STUB_LEDGER_CHECK:-0}" ;;
    --release)
        if [ -n "${STUB_LEDGER_LISTING:-}" ]; then cat "$STUB_LEDGER_LISTING"; exit "${STUB_LEDGER_RELEASE:-1}"; fi
        if [ -n "${STUB_LEDGER_RELEASE:-}" ]; then echo "ledger: there is no ledger at Docs/Process/ledger.md" >&2; exit "$STUB_LEDGER_RELEASE"; fi
        echo "ledger: every package is Done (293 rows; 2 OPT packages awaiting their trigger and 1 retired package hold nothing up)" ;;
esac
EOS
chmod +x "$S/Scripts/golden.sh" "$S/Scripts/spec-crosscheck.sh" "$S/Scripts/tests/run-all.sh" "$S/Scripts/ledger.sh"

cr() {   # <number> <status> [<approved by> <approved on>]: a change request with the template's table
    printf '# %s\n\n| Field | Value |\n|---|---|\n| Status | %s |\n| Approved by | %s |\n| Approved on | %s |\n' "$1" "$2" "${3:-}" "${4:-}" > "$S/Docs/Process/changes/$1.md"
}

# green_tree: the scratch tree in which every item passes.
green_tree() {
    local tool package
    cp "$ROOT/Scripts/release-check.sh" "$ROOT/Scripts/ci.sh" "$S/Scripts/"
    { grep '^#' "$ROOT/Scripts/ci/allocation-audit-filters.txt"; echo "ZTronDSPCoreTests/AuditTests"; } > "$S/Scripts/ci/allocation-audit-filters.txt"
    for tool in lint-bans check-dependency-graph compile-fixtures api-digest docs coverage-gate benchmarks external-parity order-matrix check-function-effects check-perf-annotations check-registers; do
        standin "$S/Scripts/$tool.sh" "$tool"
    done
    reset_folder "$S/Docs/Process/changes"
    cr CR-001 Approved "the owner" 2026-11-20
    cr CR-002 Rejected
    printf '# Changelog\n\n## [0.1.0] - 2026-11-30\n\n- The first release.\n' > "$S/CHANGELOG.md"
    rm -f "$S/README.md" "$S/README"
    {
        printf '| WP | Title | Status |\n|---|---|---|\n'
        for package in WP-338 WP-708 WP-903a WP-903b WP-904a WP-904b WP-611b WP-611c WP-611d WP-906; do printf '| %s | a package | Done |\n' "$package"; done
    } > "$S/Docs/Process/ledger.md"
    printf '# The audit of the registers, 2026-11\n' > "$S/Docs/Numerics/register-audit-2026-11.md"
}

export ZTD_CI_XC="$S/bin/xc" ZTD_CI_XCODEBUILD="$S/bin/xcodebuild" ZTD_CI_SIMCTL="$S/bin/simctl" ZTD_CI_GALLERY="$S/bin/gallery" STUB_PRODUCTS="$S/products" STUB_ROOT="$S"
export ZTD_RELEASE_GIT="$S/bin/git" ZTD_RELEASE_DF="$S/bin/df" ZTD_RELEASE_LOGS="$S/logs" ZTD_RELEASE_MONTH=2026-11 STUB_GIT_HEAD1="$HEAD1"
unset ZTD_DERIVED ZTD_DEVICE ZTD_CONFIG ZTD_XCARGS ZTD_CI_COVERAGE_REPORT ZTD_CI_CHANGED_FILES ZTD_CI_BASE_REF GITHUB_ACTIONS ZTD_RELEASE_MIN_FREE_GIB
RC="$S/Scripts/release-check.sh"

rc() {   # <expected status> <name> <command …>: one run, from an empty log, state and folder of logs
    : > "$STUB_LOG"; reset_folder "$STUB_STATE"; reset_folder "$S/logs"
    expect_status "$1" "$2" "${@:3}"
}
logged() { if grep -q -F -- "$2" "$STUB_LOG"; then pass "$1"; else fail "$1 (the log lacks: $2)" "$(cat "$STUB_LOG")"; fi; }
not_logged() { if grep -q -F -- "$2" "$STUB_LOG"; then fail "$1 (the log holds: $2)" "$(cat "$STUB_LOG")"; else pass "$1"; fi; }

# item_line <id>: the item's result line in the summary of the last run.
item_line() {
    printf '%s\n' "$LAST_OUTPUT" | awk -v id="$1" '{ v = substr($0, 23, 18); sub(/ +$/, "", v); if (v == id) line = $0 } END { print line }'
}

# expect_item <name> <id> <verdict> [<text its message holds>]
expect_item() {
    local line verdict
    line="$(item_line "$2")"
    if [ -z "$line" ]; then fail "$1 (no result line for $2)" "$LAST_OUTPUT"; return; fi
    verdict="$(printf '%s' "$line" | cut -c1-21 | sed 's/ *$//')"
    if [ "$verdict" != "$3" ]; then fail "$1 ($2 is $verdict, expected $3)" "$line"; return; fi
    case "$line" in *"${4:-}"*) pass "$1" ;; *) fail "$1 (the line of $2 lacks: $4)" "$line" ;; esac
}

# item_lacks <name> <id> <text>: the item's message does not hold the text.
item_lacks() {
    case "$(item_line "$2")" in *"$3"*) fail "$1 (the line of $2 holds: $3)" "$(item_line "$2")" ;; *) pass "$1" ;; esac
}

# in_order <name> <text> …: the log holds each text, each first after the one before it.
in_order() {
    local name="$1" previous=0 at text
    shift
    for text in "$@"; do
        at="$(grep -n -F -m1 -- "$text" "$STUB_LOG" | cut -d: -f1)"
        if [ -z "$at" ]; then fail "$name (the log lacks: $text)" "$(cat "$STUB_LOG")"; return; fi
        if [ "$at" -le "$previous" ]; then fail "$name ($text comes before the item it follows)" "$(cat "$STUB_LOG")"; return; fi
        previous="$at"
    done
    pass "$name"
}

listing() {   # <file> <line> …: a listing of Scripts/ledger.sh --release
    local file="$1"
    shift
    printf '%s\n' "$@" > "$file"
}

# ---------------------------------------------------------------------------------------------
# Every item passes
# ---------------------------------------------------------------------------------------------
green_tree
rc 0 "with every command passing and every record in order, every item passes" "$RC"
expect_contains "… 39 items, all passed" "release-check: 39 items: 39 passed, 0 failed, 0 open"
expect_contains "… and 0.1.0 can be tagged on HEAD" "release-check: every item passed: 0.1.0 can be tagged on HEAD $HEAD1"
expect_contains "the first line names the version, HEAD and the release month" "HEAD $HEAD1, release month 2026-11"
expect_item "a gate passes on its line in ci.sh's summary" gate-1 PASS "passed — ci: no gate failed"
expect_item "… with the minutes it took, the first item too" gate-1 PASS "passed — ci: no gate failed (0 min)"
expect_item "what runs no command has no minutes" tag PASS "once this run passes, and not before"
item_lacks "… none" tag "min)"
expect_item "… gate 5 too, on the whole matrix" gate-5 PASS "passed — ci: no gate failed"
expect_item "… and gate 9" gate-9 PASS "passed"
expect_item "a command beside the gates passes on exit status 0, with its last line" function-effects PASS "check-function-effects: done (stand-in, exit 0)"
expect_item "the self-tests pass with their tally" self-tests PASS "run-all: every self-test passed (500 checks in 17 suites)"
expect_item "the cross-check of the specification passes with its tallies, not its last note" spec-crosscheck PASS "DEFECTS (0), NOTES (2)"
expect_item "the golden vectors made again: how many, and how many bit for bit" golden-reproduce PASS "2 generators made their committed files again, 1 of them bit for bit"
expect_item "the gallery's UI tests pass on the nightly job's line" gallery-ui PASS "passed — ci: no gate failed"
expect_item "the audit of the release month passes" register-audit PASS "check-registers --audit Docs/Numerics/register-audit-2026-11.md: done"
expect_item "the ledger with every row Done passes" ledger-done PASS "ledger: every package is Done"
expect_item "PLAT-3: iOS 17.5 ran the tests and the hosted suites" plat3-ios-17.5 PASS "installed; on ztdsp-ci-17-5 the tests in Debug and the gallery's hosted suites passed"
expect_item "… the newest 18.x is the one read" plat3-ios-18 PASS "on ztdsp-ci-18-6"
expect_item "… the newest 26.x" plat3-ios-26 PASS "on ztdsp-ci-26-5"
expect_item "… and iOS 27.0" plat3-ios-27.0 PASS "on ztdsp-ci-27-0"
expect_item "the iOS 15 device: its packages are Done" plat3-ios-15 PASS "WP-338, WP-904a and WP-904b are Done in the ledger"
expect_item "a device run that is Done passes" device-WP-611d PASS "WP-611d is Done in the ledger"
expect_item "every change request decided passes" change-requests PASS "every one of the 2 change requests is decided"
expect_item "a dated entry of CHANGELOG.md passes" changelog PASS "CHANGELOG.md: ## [0.1.0] - 2026-11-30"
expect_item "no README, so no snippet to check" readme PASS "there is no README, so no install snippet names a version"
expect_item "a tree that is HEAD throughout passes" clean-tree PASS "the tree was HEAD $HEAD1 throughout, with nothing uncommitted"
expect_item "no tag yet passes: the tag follows the run" tag PASS "0.1.0 is not tagged yet: the tag goes on HEAD $HEAD1 once this run passes"
in_order "the items run in the order of the checklist" "xcodebuild build -scheme ZTronDSP " "lint-bans " "compile-fixtures" "api-digest --check" "xc test-only" "coverage-gate" "golden --check --strict" "benchmarks --check" "external-parity" \
    "run-all --slow" "check-function-effects" "check-perf-annotations" "spec-crosscheck" "docs --build" "golden --reproduce" "gallery ui" \
    "check-registers --audit Docs/Numerics/register-audit-2026-11.md" "lint-bans --part 3 --part 4" "ledger --check" "ledger --release"
logged "every gate runs under --strict (gate 7 asks for the strict golden check)" "golden --check --strict"
logged "gate 5 runs on the matrix" "xc test-only [config=Debug device=ztdsp-ci-27-0 derived=ci xcargs=-enableCodeCoverage YES]"
logged "… and under the Thread Sanitizer" "xc test [config= device= derived=ci-tsan xcargs=-enableThreadSanitizer YES]"
logged "the gallery's UI tests run on the matrix" "gallery ui [config=Debug device=ztdsp-ci-17-5 derived=ci-gallery]"
logged "the disk is read before a command" "df -g $S"
if [ -f "$S/logs/05-gate-5.log" ] && [ -f "$S/logs/20-ledger-done.log" ] && grep -q "ci: ===== summary =====" "$S/logs/05-gate-5.log"; then
    pass "each command has its log in the run's folder"
else
    fail "each command has its log in the run's folder" "$(ls "$S/logs")"
fi
if [ "$(grep -c . "$S/logs/summary.txt")" -eq 41 ]; then pass "summary.txt holds the 39 result lines, the tally and the verdict"; else fail "summary.txt holds the 39 result lines, the tally and the verdict" "$(cat "$S/logs/summary.txt")"; fi
rc 0 "--keep-going is accepted, and is what the script always does" "$RC" --keep-going

# ---------------------------------------------------------------------------------------------
# Failures, and what keeps going after them
# ---------------------------------------------------------------------------------------------
rc 1 "a gate that fails fails the run" env STUB_COMPILE_FIXTURES=1 "$RC"
expect_item "… its item says what failed" gate-3 FAIL "FAILED — compile fixtures"
expect_item "… and the gates after it still run" gate-9 PASS "passed"
expect_item "… and the items after the gates" tag PASS
expect_contains "… the tally counts it" "release-check: 39 items: 38 passed, 1 failed, 0 open"
expect_contains "… and the verdict says so" "release-check: FAILED: 0.1.0 is not ready to tag"
rc 1 "--allow-open does not let a failure through" env STUB_COMPILE_FIXTURES=1 "$RC" --allow-open
rc 1 "a command beside the gates that fails fails its item" env STUB_CHECK_PERF_ANNOTATIONS=2 "$RC"
expect_item "… with its exit status and last line" perf-annotations FAIL "exit 2: check-perf-annotations: done (stand-in, exit 2)"
rc 1 "the registers' check reads lint-bans parts 3 and 4 alone" env STUB_LINT_BANS_PART=1 "$RC"
expect_item "… which fail the registers item" registers FAIL "exit 1: lint-bans --part 3 --part 4"
expect_item "… and not gate 2, whose lint-bans run is another" gate-2 PASS
rc 1 "a self-test that fails fails the item" env STUB_RUN_ALL=1 "$RC"
expect_item "… with run-all's verdict" self-tests FAIL "exit 1: run-all: FAILED: ci (1 of 500 checks failed)"
rc 1 "a self-test check skipped for want of a build fails the item, though run-all exits 0" env STUB_RUN_ALL_SKIP="seeded violations of the gates: there is no build at /x (run Scripts/xc.sh build)" "$RC"
expect_item "… and names the skip" self-tests FAIL "this machine could close what was skipped: seeded violations of the gates: there is no build at /x"
rc 1 "a self-test check skipped for a tool that is not installed leaves the item open" env STUB_RUN_ALL_SKIP="the Octave run: Octave is not installed" "$RC"
expect_item "… open, not installed" self-tests "OPEN (not installed)" "1 skipped"
rc 1 "a defect of the cross-check fails its item" env STUB_SPEC_CROSSCHECK=1 "$RC"
expect_item "… with its tallies" spec-crosscheck FAIL "exit 1: DEFECTS (1), NOTES (2)"
rc 1 "a golden vector that is not made again fails its item" env STUB_GOLDEN_REPRODUCE=1 "$RC"
expect_item "… and names the generator" golden-reproduce FAIL "exit 1: golden: FAILED windows does not reproduce its committed files:"
rc 1 "a generator skipped for an oracle that is not installed leaves the item open, though golden.sh exits 0" env STUB_GOLDEN_SKIPPED=1 "$RC"
expect_item "… open, with the generator and its oracle" golden-reproduce "OPEN (not installed)" "not run, for an oracle that is not installed: tempogram (librosa)"
rc 1 "a failing ledger check fails its item" env STUB_LEDGER_CHECK=1 "$RC"
expect_item "… with the check's last line" ledger FAIL "exit 1: ledger: 293 rows, consistent with §12 and §11"

# ---------------------------------------------------------------------------------------------
# Skips: open for the owner or for a machine with more installed; failed when this one could close them
# ---------------------------------------------------------------------------------------------
rc 1 "a gate skipped for want of a baseline on this runner is open for the owner" env STUB_BENCHMARKS=3 "$RC"
expect_item "… open (owner), with the skip's own words, whatever they hold" gate-8 "OPEN (owner)" "SKIPPED — skipped: the benchmark regression check: there is no baseline for this runner (the budgets of §5.7 were held; nothing was compared)"
expect_contains "… and without --allow-open the run does not pass" "release-check: 1 item(s) are open: 0.1.0 is not ready to tag (--allow-open accepts open items)"
rc 0 "with --allow-open an open item lets the run pass" env STUB_BENCHMARKS=3 "$RC" --allow-open
expect_contains "… and the verdict still says 0.1.0 is not ready" "release-check: nothing failed; 1 item(s) are open (--allow-open): 0.1.0 is not ready to tag"
rc 0 "the golden scripts skipped where Octave is not installed: the gate is open" env STUB_GOLDEN_OCTAVE=3 "$RC" --allow-open
expect_item "… open (not installed)" gate-7 "OPEN (not installed)" "PASSED IN PART — skipped: the golden MATLAB scripts under GNU Octave: Octave is not installed (brew install octave)"
rc 0 "a runtime of PLAT-3 that is not installed leaves gate 5, PLAT-3 and the UI tests open" env STUB_SIMCTL_WITHOUT=26 "$RC" --allow-open
expect_item "… gate 5" gate-5 "OPEN (not installed)" "the iOS 26.x simulator runtime of PLAT-3 is not installed"
expect_item "… the runtime's PLAT-3 item" plat3-ios-26 "OPEN (not installed)" "the iOS 26.x simulator runtime of PLAT-3 is not installed on this machine"
expect_item "… the UI tests on the matrix" gallery-ui "OPEN (not installed)"
expect_item "… and not the other runtimes" plat3-ios-27.0 PASS
expect_contains "… three items open" "release-check: 39 items: 36 passed, 0 failed, 3 open"
rc 1 "a gate skipped for a reason this machine could close fails" env STUB_COMPILE_FIXTURES=3 "$RC" --allow-open
expect_item "… and names the skip" gate-3 FAIL "PASSED IN PART, and this machine could close what was skipped: there is no compile fixture under Tests/CompileFixtures"
rm "$S/Scripts/external-parity.sh"
rc 1 "a gate skipped because its script is missing fails" "$RC" --allow-open
expect_item "… as a skip this machine could close" gate-9 FAIL "SKIPPED, and this machine could close what was skipped: the external parity suite: Scripts/external-parity.sh does not exist yet"
green_tree
grep '^#' "$ROOT/Scripts/ci/allocation-audit-filters.txt" > "$S/Scripts/ci/allocation-audit-filters.txt"
rc 1 "a skip that is closable fails a gate even beside a runtime that is not installed" env STUB_SIMCTL_WITHOUT=26 "$RC" --allow-open
expect_item "… naming only the closable one" gate-5 FAIL "PASSED IN PART, and this machine could close what was skipped: the Release run of the allocation-audit tests: no test calls expectNoAllocations yet"
item_lacks "… and not the runtime" gate-5 "simulator runtime of PLAT-3"
green_tree

# ---------------------------------------------------------------------------------------------
# PLAT-3, read from the log of gate 5
# ---------------------------------------------------------------------------------------------
rc 1 "tests that fail on one runtime fail its PLAT-3 item" env STUB_XC_FAILING_DEVICE=ztdsp-ci-18-6 "$RC"
expect_item "… which says what failed there" plat3-ios-18 FAIL "installed; on ztdsp-ci-18-6 the tests in Debug failed"
expect_item "… and not the others" plat3-ios-17.5 PASS
expect_item "… gate 5 fails with it" gate-5 FAIL "tests in Debug on ztdsp-ci-18-6"
rc 1 "a known issue in the hosted suites on one runtime fails its PLAT-3 item" env STUB_GALLERY_KNOWN=ztdsp-ci-27-0 "$RC"
expect_item "… and says so" plat3-ios-27.0 FAIL "installed; on ztdsp-ci-27-0 the gallery's hosted suites failed"
rc 1 "a runtime for which no simulator can be made fails its PLAT-3 item" env STUB_SIMCTL_CREATE=1 "$RC"
expect_item "… and says so" plat3-ios-17.5 FAIL "the iOS 17.5 runtime is installed, and no simulator could be made for it"
printf '#!/bin/bash\necho "ci: broken before its summary"\nexit 1\n' > "$S/Scripts/ci.sh"
rc 1 "ci.sh that ends without a summary fails every gate" "$RC"
expect_item "… with its last line" gate-1 FAIL "Scripts/ci.sh gave no summary line for gate 1 (exit 1): ci: broken before its summary"
expect_item "… and the nightly job" gallery-ui FAIL "Scripts/ci.sh gave no summary line for nightly"
expect_item "… and PLAT-3, which no test of gate 5 shows" plat3-ios-17.5 FAIL "gate 5 ran no test on a simulator of iOS 17.5"
green_tree

# ---------------------------------------------------------------------------------------------
# The ledger, the device runs, the change requests
# ---------------------------------------------------------------------------------------------
listing "$S/listing" "ledger: WP-338 Blocked-on-deps" "ledger: WP-611b Implementing" "ledger: WP-904a Blocked-on-deps" "ledger: 3 of 293 rows are not Done: 2 Blocked-on-deps, 1 Implementing"
rc 1 "rows that are not Done, every one a device run, leave the ledger open" env STUB_LEDGER_LISTING="$S/listing" "$RC"
expect_item "… open (device)" ledger-done "OPEN (device)" "ledger: 3 of 293 rows are not Done: 2 Blocked-on-deps, 1 Implementing: every one of them is a device run"
expect_item "… each device run that is not Done is open, with its status" device-WP-338 "OPEN (device)" "WP-338 is Blocked-on-deps in the ledger: a run on a device"
expect_item "… a crossover too" device-WP-611b "OPEN (device)" "WP-611b is Implementing in the ledger"
expect_item "… a device run that is Done passes" device-WP-708 PASS "WP-708 is Done in the ledger"
expect_item "… and the iOS 15 device names the packages it waits for" plat3-ios-15 "OPEN (device)" "iOS 15 and 16 cannot be simulated on this host (E-17): WP-338 Blocked-on-deps, WP-904a Blocked-on-deps"
expect_contains "… which leaves 5 items open" "release-check: 39 items: 34 passed, 0 failed, 5 open"
listing "$S/listing" "ledger: WP-338 Blocked-on-deps" "ledger: WP-906 Verifying" "ledger: 2 of 293 rows are not Done: 1 Blocked-on-deps, 1 Verifying"
rc 1 "a row not Done that is no device run fails the ledger" env STUB_LEDGER_LISTING="$S/listing" "$RC" --allow-open
expect_item "… with the tally" ledger-done FAIL "ledger: 2 of 293 rows are not Done: 1 Blocked-on-deps, 1 Verifying"
expect_item "… and the device runs are still read" device-WP-338 "OPEN (device)"
listing "$S/listing" "Traceback (most recent call last):" "KeyError: 'Status'"
rc 1 "a listing without its tally is no listing" env STUB_LEDGER_LISTING="$S/listing" "$RC" --allow-open
expect_item "… the ledger fails" ledger-done FAIL "exit 1: KeyError: 'Status'"
expect_item "… and no device run is taken for Done" device-WP-338 FAIL "the ledger could not be read (ledger-done)"
rc 1 "a ledger that cannot be read fails the ledger and every device run" env STUB_LEDGER_RELEASE=2 "$RC" --allow-open
expect_item "… the ledger" ledger-done FAIL "exit 2: ledger: there is no ledger at Docs/Process/ledger.md"
expect_item "… a device run" device-WP-904b FAIL "the ledger could not be read (ledger-done)"
expect_item "… and the iOS 15 device" plat3-ios-15 FAIL "the ledger could not be read (ledger-done)"
grep -v -E '^\| (WP-708|WP-904b) ' "$S/Docs/Process/ledger.md" > "$S/ledger.md" && mv "$S/ledger.md" "$S/Docs/Process/ledger.md"
rc 1 "a device run that has no row in the ledger is not taken for Done" "$RC" --allow-open
expect_item "… it fails" device-WP-708 FAIL "WP-708 has no row in Docs/Process/ledger.md"
expect_item "… and the iOS 15 device names it" plat3-ios-15 FAIL "no row in Docs/Process/ledger.md for WP-904b"
green_tree

cr CR-002 Proposed
rc 1 "a change request still Proposed is open for the owner" "$RC"
expect_item "… with its name" change-requests "OPEN (owner)" "1 of 2 change requests are Proposed, for the owner to decide: CR-002"
cr CR-001 Approved
rc 1 "an Approved change request without the owner's name and date fails" "$RC" --allow-open
expect_item "… and is named" change-requests FAIL "CR-001 is Approved without the owner's name and date"
cr CR-001 Accepted
rc 1 "a status that is not the template's fails" "$RC" --allow-open
expect_item "… and is named" change-requests FAIL "CR-001 has the status 'Accepted', which is not one of the template's"
reset_folder "$S/Docs/Process/changes"
rc 0 "no change request at all passes" "$RC"
expect_item "… and says so" change-requests PASS "there is no change request"
green_tree

# ---------------------------------------------------------------------------------------------
# What a tag needs: CHANGELOG.md, the README, a tree that is HEAD, no tag elsewhere
# ---------------------------------------------------------------------------------------------
printf '# Changelog\n\n## [0.1.0] - Unreleased\n' > "$S/CHANGELOG.md"
rc 1 "an entry of CHANGELOG.md without its date is open for the owner" "$RC"
expect_item "… who dates it on release" changelog "OPEN (owner)" "CHANGELOG.md: \"## [0.1.0] - Unreleased\": the date goes in when the owner releases 0.1.0"
printf '# Changelog\n\n## [0.0.9] - 2026-01-01\n' > "$S/CHANGELOG.md"
rc 1 "CHANGELOG.md without an entry for 0.1.0 fails" "$RC"
expect_item "… and says which heading it wants" changelog FAIL "CHANGELOG.md has no entry for 0.1.0"
rm "$S/CHANGELOG.md"
rc 1 "no CHANGELOG.md fails" "$RC"
expect_item "… and says so" changelog FAIL "there is no CHANGELOG.md"
green_tree
printf '# ZTronDSP\n\nAdd the package to Package.swift.\n' > "$S/README.md"
rc 1 "a README without the install snippet of 0.1.0 fails" "$RC"
expect_item "… and shows the snippet it wants" readme FAIL "README.md has no install snippet that names 0.1.0"
printf '# ZTronDSP\n\n    .package(url: "https://example.invalid/ZTronDSP.git", from: "0.1.0")\n' > "$S/README.md"
rc 0 "a README whose snippet names 0.1.0 passes" "$RC"
expect_item "… and says so" readme PASS "README.md: the install snippet names 0.1.0"
green_tree

rc 1 "a tree that differs from HEAD when the run begins fails" env STUB_GIT_STATUS_START=" M Scripts/ci.sh" "$RC" --allow-open
expect_item "… what was checked is in no commit" clean-tree FAIL "1 path(s) differed from HEAD when the run began"
rc 1 "a run that changes the tree fails" env STUB_GIT_STATUS_LATER="?? stray.txt" "$RC" --allow-open
expect_item "… and names what changed" clean-tree FAIL "the run changed the tree: ?? stray.txt"
rc 1 "HEAD that moves during the run fails" env STUB_GIT_HEAD_LATER="$HEAD2" "$RC" --allow-open
expect_item "… from one commit to the other" clean-tree FAIL "HEAD moved during the run, from $HEAD1 to $HEAD2"
rc 1 "no repository fails: there is nothing to tag" env STUB_GIT_NO_REPO=1 "$RC" --allow-open
expect_item "… and says so" clean-tree FAIL "there is no git commit here, so nothing could be tagged"
rc 1 "a tag 0.1.0 on another commit fails" env STUB_GIT_TAG="$OTHER" "$RC" --allow-open
expect_item "… and names it" tag FAIL "0.1.0 already names $OTHER, which is not HEAD $HEAD1"
rc 0 "a tag 0.1.0 on HEAD passes" env STUB_GIT_TAG="$HEAD1" "$RC"
expect_item "… and says so" tag PASS "0.1.0 is HEAD $HEAD1"

# ---------------------------------------------------------------------------------------------
# The disk, the month of the audit, usage
# ---------------------------------------------------------------------------------------------
rc 1 "below the floor of free space no command starts" env STUB_DF_FREE=3 "$RC" --allow-open
expect_item "… each command's item fails, not started" gate-1 FAIL "not started: 3 GiB free on the package's disk, below the floor of 6 GiB (ZTD_RELEASE_MIN_FREE_GIB)"
expect_item "… the last command too" ledger-done FAIL "not started"
not_logged "… no gate was started" "xcodebuild"
not_logged "… nor anything beside the gates" "run-all"
expect_item "… PLAT-3 then says that gate 5 did not run" plat3-ios-17.5 FAIL "gate-5 did not run, so nothing says whether the iOS 17.5 simulator ran the tests"
expect_item "… what runs no command is still read" change-requests PASS
rc 0 "a lower floor lets the commands start" env STUB_DF_FREE=3 ZTD_RELEASE_MIN_FREE_GIB=2 "$RC"
rc 0 "a disk whose free space cannot be read does not stop the run" env ZTD_RELEASE_DF=false "$RC"
rc 1 "an audit of the registers missing for the release month fails" env ZTD_RELEASE_MONTH=2026-12 "$RC" --allow-open
expect_item "… and names the file that WP-905 writes" register-audit FAIL "there is no audit of 2026-12, Docs/Numerics/register-audit-2026-12.md: WP-905 repeats it before every release (§7.3)"
not_logged "… and the audit is not run on another month's file" "check-registers"
rc 0 "--list names each item and its command" "$RC" --list
if [ "$(printf '%s\n' "$LAST_OUTPUT" | grep -c .)" -eq 39 ]; then pass "… 39 items"; else fail "… 39 items" "$LAST_OUTPUT"; fi
expect_contains "… gate 5 on the matrix, under the Thread Sanitizer" "gate-5             Scripts/ci.sh --strict --gate 5 --matrix --tsan"
expect_contains "… the audit of the release month" "register-audit     Scripts/check-registers.sh --audit Docs/Numerics/register-audit-2026-11.md"
if [ -s "$STUB_LOG" ] || [ -n "$(ls -A "$S/logs")" ]; then fail "… and runs nothing" "$(cat "$STUB_LOG"; ls "$S/logs")"; else pass "… and runs nothing"; fi
expect_status 0 "--help prints the header" "$RC" --help
expect_contains "… with the option that accepts open items" "Scripts/release-check.sh --allow-open"
expect_status 2 "an unknown option is a usage error" "$RC" --everything
expect_status 2 "a release month that is no month is a usage error" env ZTD_RELEASE_MONTH=2026-13 "$RC"
expect_status 2 "a floor that is no number is a usage error" env ZTD_RELEASE_MIN_FREE_GIB=six "$RC"

# ---------------------------------------------------------------------------------------------
# The checklist and the script name the same items, in the same order, with the same commands
# ---------------------------------------------------------------------------------------------
CHECKLIST="$ROOT/Docs/Release/0.1.0-checklist.md"
if [ ! -f "$CHECKLIST" ]; then
    fail "the checklist exists" "$CHECKLIST"
else
    listed="$(env ZTD_RELEASE_MONTH=2026-11 "$ROOT/Scripts/release-check.sh" --list)"
    script_ids="$(printf '%s\n' "$listed" | awk '{ print $1 }' | tr '\n' ' ')"
    checklist_ids="$(sed -n -E 's/^\| *[^|]* *\| *`([A-Za-z0-9.-]+)` *\|.*/\1/p' "$CHECKLIST" | tr '\n' ' ')"
    if [ "$script_ids" = "$checklist_ids" ]; then
        pass "the checklist names the items of release-check.sh, in its order"
    else
        fail "the checklist names the items of release-check.sh, in its order" "script:    $script_ids
checklist: $checklist_ids"
    fi
    missing=""
    while read -r id command; do
        case "$command" in "("*|"") continue ;; esac
        generic="$(printf '%s' "$command" | sed -E 's/register-audit-[0-9]{4}-[0-9]{2}/register-audit-YYYY-MM/')"
        row="$(awk -F'|' -v id="\`$id\`" '{ cell = $3; gsub(/^ +| +$/, "", cell); if (cell == id) { print; exit } }' "$CHECKLIST")"
        case "$row" in *"\`$generic\`"*) ;; *) missing="$missing $id" ;; esac
    done <<EOF_LISTED
$listed
EOF_LISTED
    if [ -z "$missing" ]; then pass "… and each item's row shows the command the script runs"; else fail "… and each item's row shows the command the script runs" "rows without their command:$missing"; fi
fi

finish
