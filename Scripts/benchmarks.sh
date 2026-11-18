#!/bin/bash
# The benchmark run and its regression check (WP-006; PERF-1, §10.1; §5.7; CI gate 8 of §10.3).
#
#   Scripts/benchmarks.sh                  run the benchmark suites and print what they measured
#   Scripts/benchmarks.sh --check          … and compare with the baseline: a workload more than
#                                          10 % slower, or one the baseline holds and the run did
#                                          not measure, fails
#   Scripts/benchmarks.sh --update         … and keep the report as the baseline of this runner
#   Scripts/benchmarks.sh --compare FILE   compare an existing report with the baseline; nothing is run
#
# Options: --launches N (default 3: each suite is launched N times and the best launch of each
# workload is kept), --allow FRACTION (default 0.10).
#
# A benchmark run is an optimised build, one suite at a time, nothing in parallel, with
# ZTD_BENCHMARK_OUTPUT set. That is also the only run in which a test holds a timing against its
# budget (§5.7), so a suite that misses a budget fails here and nowhere else.
#
# Suites: Scripts/ci/benchmark-filters.txt, one `xcodebuild -only-testing:` filter per line.
# Baseline: Tests/Benchmarks/baseline.json, and beside it runner.txt, the machine it was measured
# on. Timings of another machine say nothing about this one: where the runner differs, or there
# is no baseline yet, --check measures, holds the budgets, prints, and compares nothing.
#
# Exit status: 0 ok, 1 a regression, a workload that went unmeasured or a failed suite, 2 usage
# error, 3 nothing was compared (no baseline, or not the pinned runner).

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT/Scripts/lib/benchmarks.py"
XC="${ZTD_BENCHMARKS_XC:-$ROOT/Scripts/xc.sh}"
BASELINE="${ZTD_BENCHMARKS_BASELINE:-$ROOT/Tests/Benchmarks/baseline.json}"
RUNNER_FILE="$(dirname "$BASELINE")/runner.txt"
FILTERS="${ZTD_BENCHMARKS_FILTERS:-$ROOT/Scripts/ci/benchmark-filters.txt}"

mode=run; launches=3; allow=0.10; report=""
while [ $# -gt 0 ]; do
    case "$1" in
        --check) mode=check ;;
        --update) mode=update ;;
        --compare)
            [ $# -ge 2 ] || { echo "benchmarks: --compare takes a report" >&2; exit 2; }
            mode=compare; report="$2"; shift ;;
        --launches)
            [ $# -ge 2 ] || { echo "benchmarks: --launches takes a number" >&2; exit 2; }
            case "$2" in ''|*[!0-9]*|0) echo "benchmarks: --launches takes a number from 1 up" >&2; exit 2 ;; esac
            launches="$2"; shift ;;
        --allow)
            [ $# -ge 2 ] || { echo "benchmarks: --allow takes a fraction" >&2; exit 2; }
            allow="$2"; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "benchmarks: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done

runner="$(python3 "$LIB" runner)"

# compare_with_baseline <report>: 0 ok, 1 regression, 3 nothing compared.
compare_with_baseline() {
    if [ ! -f "$BASELINE" ]; then
        echo "benchmarks: there is no baseline at ${BASELINE#"$ROOT"/}: nothing is compared (Scripts/benchmarks.sh --update records one)"
        return 3
    fi
    local pinned=""
    [ -f "$RUNNER_FILE" ] && pinned="$(head -1 "$RUNNER_FILE")"
    if [ "$pinned" != "$runner" ]; then
        echo "benchmarks: the baseline was measured on \"$pinned\" and this is \"$runner\": nothing is compared"
        return 3
    fi
    python3 "$LIB" compare --baseline "$BASELINE" --report "$1" --allow "$allow"
}

if [ "$mode" = compare ]; then
    [ -f "$report" ] || { echo "benchmarks: no report at $report" >&2; exit 2; }
    compare_with_baseline "$report"
    exit $?
fi

filters=()
if [ -f "$FILTERS" ]; then
    while IFS= read -r line; do
        line="${line%%#*}"; line="$(printf '%s' "$line" | tr -d '[:space:]')"
        [ -n "$line" ] && filters+=("$line")
    done < "$FILTERS"
fi
if [ "${#filters[@]}" -eq 0 ]; then
    echo "benchmarks: ${FILTERS#"$ROOT"/} names no suite" >&2
    exit 2
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ztd-benchmarks.XXXXXX")" || { echo "benchmarks: cannot make a scratch folder" >&2; exit 2; }
trap 'case "$scratch" in */ztd-benchmarks.??????) rm -rf "$scratch" ;; esac' EXIT

echo "benchmarks: runner \"$runner\"; ${#filters[@]} suites, $launches launch(es) each, Release, one test at a time"
ZTD_CONFIG=Release "$XC" build >"$scratch/build.log" 2>&1 || { tail -20 "$scratch/build.log"; echo "benchmarks: the Release build failed" >&2; exit 1; }

failed=0; parts=()
for filter in "${filters[@]}"; do
    name="$(printf '%s' "$filter" | tr '/' '_')"
    for launch in $(seq 1 "$launches"); do
        out="$scratch/$name.$launch.json"
        if TEST_RUNNER_ZTD_BENCHMARK_OUTPUT="$out" ZTD_CONFIG=Release ZTD_XCARGS="-parallel-testing-enabled NO" \
            "$XC" test-only "$filter" >"$scratch/$name.$launch.log" 2>&1; then
            [ -f "$out" ] && parts+=("$out")
        else
            # A budget is met when one launch of the suite meets it: the others were disturbed.
            [ -f "$out" ] && parts+=("$out")
            echo "$filter" >> "$scratch/failed.$name"
            grep -aE "^✘|recorded an issue" "$scratch/$name.$launch.log" | cut -c1-300 | head -6 | sed "s/^/benchmarks:   launch $launch of $filter: /"
        fi
    done
    if [ -f "$scratch/failed.$name" ] && [ "$(wc -l < "$scratch/failed.$name" | tr -d ' ')" -ge "$launches" ]; then
        echo "benchmarks: FAILED: $filter failed in each of its $launches launch(es): a budget of §5.7 is missed, or a test is broken"
        failed=1
    fi
done

if [ "${#parts[@]}" -eq 0 ]; then
    echo "benchmarks: no suite recorded a benchmark" >&2
    exit 1
fi
python3 "$LIB" merge "$scratch/report.json" "${parts[@]}" || exit 2
python3 - "$scratch/report.json" <<'PY'
import json, sys
results = json.load(open(sys.argv[1], encoding="utf-8"))["results"]
width = max(len(result["name"]) for result in results)
for result in results:
    print("benchmarks: %-*s  %12.1f ns  (median %.1f)" % (width, result["name"], result["minimum"], result["median"]))
PY

case "$mode" in
    run)
        exit $failed ;;
    update)
        if [ "$failed" -ne 0 ]; then echo "benchmarks: the baseline is not replaced by a run that failed" >&2; exit 1; fi
        mkdir -p "$(dirname "$BASELINE")"
        cp "$scratch/report.json" "$BASELINE"
        printf '%s\n' "$runner" > "$RUNNER_FILE"
        echo "benchmarks: baseline written to ${BASELINE#"$ROOT"/} for \"$runner\""
        exit 0 ;;
    check)
        compare_with_baseline "$scratch/report.json"; status=$?
        if [ "$failed" -ne 0 ]; then exit 1; fi
        exit $status ;;
esac
