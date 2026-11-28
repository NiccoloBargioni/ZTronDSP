#!/bin/bash
# Runs the self-test of every script under Scripts/ (the tooling of M0: WP-001…WP-003,
# WP-007…WP-014). Every self-test is driven by fixtures under Tests/Fixtures and fails when
# its script stops doing what the fixture shows.
#
#   Scripts/tests/run-all.sh             every self-test; prints failures, skips and the tally
#   Scripts/tests/run-all.sh --verbose   prints every check
#   Scripts/tests/run-all.sh --slow      also the checks that build the package for real
#                                        (gate 1 of Scripts/ci.sh with a seeded compiler warning)
#
# No simulator test is run. The checks that read a build of the package (the package's own
# compile fixtures and API digest, the seeded violations of the gates) are skipped, loudly,
# when there is none: run Scripts/xc.sh build first.
# Exit status: 0 every self-test passed, 1 otherwise.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verbose=0; slow=0
for argument in "$@"; do
    case "$argument" in
        --verbose) verbose=1 ;;
        --slow) slow=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "run-all: unknown argument $argument" >&2; exit 2 ;;
    esac
done

SUITES="spec-crosscheck process-files check-registers lint-bans check-dependency-graph coverage-gate matlab-check golden compile-fixtures order-matrix api-digest docs benchmarks xc ci workflow external-parity release-check"
failed_suites=""; total=0; total_failed=0; skips=0
for suite in $SUITES; do
    script="$ROOT/Scripts/tests/test-$suite.sh"
    if [ ! -x "$script" ]; then
        echo "run-all: $script is missing or not executable"
        failed_suites="$failed_suites $suite"
        continue
    fi
    arguments=()
    { [ "$suite" = "ci" ] || [ "$suite" = "external-parity" ]; } && [ "$slow" -eq 1 ] && arguments=(--slow)
    output="$("$script" ${arguments[@]+"${arguments[@]}"} 2>&1)"
    status=$?
    tally="$(printf '%s\n' "$output" | tail -1)"
    if [ "$verbose" -eq 1 ]; then
        printf '%s\n' "$output"
    else
        printf '%s\n' "$output" | grep -E "^  (FAIL|SKIP|NOTE)|^          \| " || true
        printf '%-26s %s\n' "$suite" "$tally"
    fi
    checks="$(printf '%s' "$tally" | sed -n -E 's/^([0-9]+) checks, ([0-9]+) failed$/\1/p')"
    bad="$(printf '%s' "$tally" | sed -n -E 's/^([0-9]+) checks, ([0-9]+) failed$/\2/p')"
    total=$((total + ${checks:-0})); total_failed=$((total_failed + ${bad:-0}))
    skips=$((skips + $(printf '%s\n' "$output" | grep -c "^  SKIP")))
    if [ "$status" -ne 0 ] || [ -z "$checks" ]; then failed_suites="$failed_suites $suite"; fi
done

echo
if [ -n "$failed_suites" ]; then
    echo "run-all: FAILED:$failed_suites ($total_failed of $total checks failed)"
    exit 1
fi
echo "run-all: every self-test passed ($total checks in $(printf '%s\n' $SUITES | wc -l | tr -d ' ') suites$([ "$skips" -gt 0 ] && echo ", $skips skipped: see above"))"
exit 0
