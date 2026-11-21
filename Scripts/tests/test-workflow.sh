#!/bin/bash
# Self-test of .github/workflows/ci.yml (WP-014): the file parses, and it runs the gates of
# §10.3 in order through Scripts/ci.sh. The workflow itself cannot be run here; what a gate
# does with a violation is the business of test-ci.sh.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yml"

echo "workflow"
if command -v ruby >/dev/null 2>&1; then
    JSON="$(ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' "$WORKFLOW" 2>&1)" || { fail "the workflow is valid YAML" "$JSON"; finish; exit 1; }
elif python3 -c 'import yaml' >/dev/null 2>&1; then
    JSON="$(python3 -c 'import json, sys, yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1]))))' "$WORKFLOW" 2>&1)" || { fail "the workflow is valid YAML" "$JSON"; finish; exit 1; }
else
    echo "  SKIP  the workflow's structure: neither ruby nor PyYAML is here to parse YAML"
    finish; exit $?
fi
pass "the workflow is valid YAML"

LAST_OUTPUT="$(printf '%s' "$JSON" | python3 -c '
import json, re, sys
workflow = json.load(sys.stdin)
jobs = workflow["jobs"]

def needs(name, seen=None):
    """Every job that `name` waits for, directly or not."""
    seen = set() if seen is None else seen
    wanted = jobs[name].get("needs", [])
    for other in ([wanted] if isinstance(wanted, str) else wanted):
        if other not in seen:
            seen.add(other)
            needs(other, seen)
    return seen

where = {}      # gate number: [(job, step index)]
for name, job in jobs.items():
    for index, step in enumerate(job.get("steps", [])):
        run = step.get("run", "") or ""
        if "Scripts/ci.sh" not in run:
            continue
        for gate in re.findall(r"--gate (\d)", run):
            where.setdefault(int(gate), []).append((name, index))
        print("job %s runs: %s" % (name, " ".join(run.split())))

for gate in range(1, 10):
    print("gate %d: %s" % (gate, "run by " + ", ".join(sorted({job for job, _ in where[gate]})) if gate in where else "MISSING"))
for gate in range(2, 10):
    if gate not in where or gate - 1 not in where:
        continue
    for job, index in where[gate]:
        before = [(j, i) for j, i in where[gate - 1]]
        ordered = any((j == job and i < index) or j in needs(job) for j, i in before)
        print("gate %d after gate %d in %s: %s" % (gate, gate - 1, job, "yes" if ordered else "NO"))

matrix = jobs["gate-5-tests"]["strategy"]["matrix"]["runtime"]
print("matrix: " + " ".join(matrix))
print("matrix covers PLAT-3: %s" % ("yes" if "iOS-17-5" in matrix and "iOS-27-0" in matrix and any(r.startswith("iOS-18-") for r in matrix) and any(r.startswith("iOS-26-") for r in matrix) else "NO"))
print("thread sanitizer job: %s" % ("yes" if any("--tsan" in (s.get("run") or "") for j in jobs.values() for s in j.get("steps", [])) else "NO"))
bench = jobs["gate-8-benchmarks"]["runs-on"]
print("benchmarks on a pinned runner: %s" % ("yes" if isinstance(bench, list) and "self-hosted" in bench and "ztrondsp-benchmark" in bench else "NO"))
print("self-tests of the gates: %s" % ("yes" if any("Scripts/tests/run-all.sh" in (s.get("run") or "") for j in jobs.values() for s in j.get("steps", [])) else "NO"))
print("strict run by dispatch: %s" % ("yes" if "--strict" in workflow.get("env", {}).get("ZTD_CI_STRICT", "") else "NO"))

# The UI tests of the gallery: a nightly job through `Scripts/ci.sh --nightly`, not a gate; the nightly
# run skips the gates. YAML 1.1 reads the key `on` as true, which JSON writes as "true". These lines say
# "no", not "NO": the check of the order of the gates looks for ": NO" in the whole output.
triggers = workflow.get("on") or workflow.get("true") or workflow.get(True) or {}
nightly = sorted(name for name, job in jobs.items() if any("Scripts/ci.sh --nightly" in (s.get("run") or "") for s in job.get("steps", [])))
print("nightly job: %s" % (" ".join(nightly) or "missing"))
scheduled = isinstance(triggers, dict) and bool(triggers.get("schedule")) and bool(nightly) and all("schedule" in str(jobs[n].get("if", "")) for n in nightly)
print("nightly job on a schedule: %s" % ("yes" if scheduled else "no"))
print("nightly job is not a gate: %s" % ("yes" if nightly and not any(re.search(r"--gate \d", s.get("run") or "") or jobs[n].get("needs") for n in nightly for s in jobs[n].get("steps", [])) else "no"))
print("the nightly run skips the gates: %s" % ("yes" if all("schedule" in str(jobs[n].get("if", "")) for n in ("gates-1-4", "gate-9-external-parity")) else "no"))
' 2>&1)"
for gate in 1 2 3 4 5 6 7 8 9; do expect_contains "gate $gate is run through Scripts/ci.sh" "gate $gate: run by"; done
expect_lacks "every gate runs after the one before it (§10.3: in order)" ": NO"
expect_lacks "no gate is missing" "MISSING"
expect_contains "the simulator matrix is the one of PLAT-3" "matrix covers PLAT-3: yes"
expect_contains "there is a Thread Sanitizer job" "thread sanitizer job: yes"
expect_contains "benchmarks run on a pinned runner" "benchmarks on a pinned runner: yes"
expect_contains "the self-tests of the gates run too" "self-tests of the gates: yes"
expect_contains "a strict run can be dispatched" "strict run by dispatch: yes"
expect_contains "the tests of gate 5 name their runtime" "--gate 5 --runtime com.apple.CoreSimulator.SimRuntime.\${{ matrix.runtime }}"
expect_contains "the gallery's UI tests run in a job of their own" "nightly job: gallery-ui-nightly"
expect_contains "… on a schedule" "nightly job on a schedule: yes"
expect_contains "… which is not a gate" "nightly job is not a gate: yes"
expect_contains "… on each runtime of the matrix" "Scripts/ci.sh --nightly --runtime com.apple.CoreSimulator.SimRuntime.\${{ matrix.runtime }}"
expect_contains "the nightly run skips the gates" "the nightly run skips the gates: yes"
finish
