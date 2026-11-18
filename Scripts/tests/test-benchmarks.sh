#!/bin/bash
# Self-test of Scripts/benchmarks.sh and Scripts/lib/benchmarks.py (WP-006; CI gate 8).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/Benchmarks"
B="$ROOT/Scripts/benchmarks.sh"
LIB="$ROOT/Scripts/lib/benchmarks.py"
make_scratch benchmarks
S="$SCRATCH"

echo "benchmarks"
# A baseline of this machine: the fixture's figures, pinned to the runner the test runs on.
mkdir -p "$S/pinned" "$S/elsewhere"
cp "$F/baseline.json" "$S/pinned/baseline.json"; python3 "$LIB" runner > "$S/pinned/runner.txt"
cp "$F/baseline.json" "$S/elsewhere/baseline.json"; printf 'Another machine\n' > "$S/elsewhere/runner.txt"
pinned() { env ZTD_BENCHMARKS_BASELINE="$S/pinned/baseline.json" "$@"; }

expect_status 0 "a report within 10 % of its baseline passes" pinned "$B" --compare "$F/report-ok.json"
expect_contains "… a workload 9 % slower is shown as such" "+9.0 %"
expect_contains "… and so is one that got faster" "-22.5 %"
expect_status 1 "a workload more than 10 % slower fails" pinned "$B" --compare "$F/report-regressed.json"
expect_contains "… and is named with its change" "biquad, 8 sections, 512 frames"
expect_contains "… by the rule" "FAIL: slower by more than 10 %"
expect_status 0 "… unless more is allowed" pinned "$B" --allow 0.2 --compare "$F/report-regressed.json"
expect_status 1 "a workload of the baseline that was not measured fails" pinned "$B" --compare "$F/report-missing.json"
expect_contains "… as not measured" "FAIL: not measured"
expect_status 0 "a workload the baseline does not hold is listed, not failed" pinned "$B" --compare "$F/report-new.json"
expect_contains "… as such" "not in the baseline"
expect_status 3 "a baseline of another machine is not compared with" env ZTD_BENCHMARKS_BASELINE="$S/elsewhere/baseline.json" "$B" --compare "$F/report-regressed.json"
expect_contains "… and both machines are named" "the baseline was measured on \"Another machine\""
expect_status 3 "no baseline at all: nothing is compared" env ZTD_BENCHMARKS_BASELINE="$S/none/baseline.json" "$B" --compare "$F/report-ok.json"
expect_status 2 "a file that is not a report is refused" pinned "$B" --compare "$F/not-a-report.json"
expect_status 2 "a report that does not exist is refused" pinned "$B" --compare "$S/absent.json"
expect_status 2 "an unknown argument is refused" "$B" --nonsense

expect_status 0 "several launches are merged" python3 "$LIB" merge "$S/merged.json" "$F/baseline.json" "$F/report-ok.json" "$F/report-new.json"
if python3 - "$S/merged.json" <<'PY'
import json, sys
results = {r["name"]: r["minimum"] for r in json.load(open(sys.argv[1]))["results"]}
sys.exit(0 if results == {"gain, 512 frames": 100.0, "biquad, 8 sections, 512 frames": 3000.0, "ring write, 512 frames": 31.0, "partitioned FIR, 4 096 taps": 9000.0} else 1)
PY
then pass "… to the best launch of each workload"; else fail "… to the best launch of each workload" "$(cat "$S/merged.json")"; fi

# The run itself, with a stand-in for Scripts/xc.sh: it records what it was asked and writes
# the report a suite would.
cat > "$S/xc.sh" <<'STUB'
#!/bin/bash
echo "xc $* [config ${ZTD_CONFIG:-Debug}] [args ${ZTD_XCARGS:-}]" >> "$STUB_LOG"
[ "$1" = "build" ] && exit "${STUB_BUILD_STATUS:-0}"
if [ "$1" = "test-only" ]; then
    count_file="$STUB_LOG.count.$(printf '%s' "$2" | tr '/' '_')"
    count=$(( $(cat "$count_file" 2>/dev/null || echo 0) + 1 )); echo "$count" > "$count_file"
    case "$2" in
        Suite/Slow) value=$(( 120 - count * 5 )) ;;      # each launch a little faster
        *) value=40 ;;
    esac
    printf '{"results": [{"name": "%s", "iterations": 1, "samples": 1, "minimum": %s, "median": %s, "mean": %s}]}\n' "$2" "$value" "$value" "$value" > "$TEST_RUNNER_ZTD_BENCHMARK_OUTPUT"
    case "${STUB_FAIL:-}" in
        always) echo "✘ Test budget() recorded an issue"; exit 1 ;;
        first) [ "$count" -eq 1 ] && { echo "✘ Test budget() recorded an issue"; exit 1; } ;;
    esac
    exit 0
fi
exit 0
STUB
chmod +x "$S/xc.sh"
printf '# two suites\nSuite/Slow\nSuite/Fast   # with a comment\n' > "$S/filters.txt"
run_stub() { : > "$S/log"; rm -f "$S"/log.count.*; env STUB_LOG="$S/log" ZTD_BENCHMARKS_XC="$S/xc.sh" ZTD_BENCHMARKS_FILTERS="$S/filters.txt" "$@"; }

expect_status 0 "a run measures every suite of the list" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B"
expect_contains "… and prints what was measured" "Suite/Fast"
if grep -q "^xc build \[config Release\]" "$S/log" && [ "$(grep -c "^xc test-only Suite/Slow \[config Release\] \[args -parallel-testing-enabled NO\]" "$S/log")" -eq 3 ]; then
    pass "… in Release, one test at a time, three launches each"
else
    fail "… in Release, one test at a time, three launches each" "$(cat "$S/log")"
fi
expect_contains "… keeping the best launch" "105.0 ns"
expect_status 0 "--launches chooses how many" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --launches 1
expect_contains "… and one launch gives its own figure" "115.0 ns"
expect_status 3 "--check without a baseline holds the budgets and compares nothing" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --check
expect_status 0 "--update records the baseline" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --update
if [ -f "$S/run/baseline.json" ] && [ "$(cat "$S/run/runner.txt")" = "$(python3 "$LIB" runner)" ]; then pass "… with the runner it was measured on"; else fail "… with the runner it was measured on"; fi
expect_status 0 "--check against that baseline passes" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --check
expect_status 0 "a suite that misses a budget in one launch of three passes" run_stub env STUB_FAIL=first ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --check
expect_status 1 "a suite that misses a budget in every launch fails" run_stub env STUB_FAIL=always ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --check
expect_contains "… and is named" "FAILED: Suite/Slow failed in each of its 3 launch(es)"
expect_status 1 "… and such a run does not replace the baseline" run_stub env STUB_FAIL=always ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B" --update
expect_status 1 "a Release build that fails fails the run" run_stub env STUB_BUILD_STATUS=1 ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B"
printf '# nothing\n' > "$S/filters.txt"
expect_status 2 "an empty list of suites is refused" run_stub env ZTD_BENCHMARKS_BASELINE="$S/run/baseline.json" "$B"

if [ -f "$ROOT/Scripts/ci/benchmark-filters.txt" ] && grep -q '^[A-Za-z]' "$ROOT/Scripts/ci/benchmark-filters.txt"; then pass "the package's own list names suites"; else fail "the package's own list names suites"; fi
finish
