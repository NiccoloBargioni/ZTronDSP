"""The benchmark regression check (WP-006; PERF-1, §10.1; CI gate 8 of §10.3).

    benchmarks.py merge OUT IN [IN…]
        The best of several launches: for each workload, the report with the smallest minimum.
    benchmarks.py compare --baseline FILE --report FILE [--allow FRACTION]
        A workload whose minimum grew by more than FRACTION (default 0.10) over the baseline's
        fails, and so does a workload the baseline holds and the report does not: a benchmark
        cannot leave the gate by being deleted. A workload the baseline does not hold is listed.
    benchmarks.py runner
        One line that names the machine timings were taken on.

A report is what `Benchmark.record` of ZTronDSPTesting writes: {"results": [{"name", "iterations",
"samples", "minimum", "median", "mean"}]}, nanoseconds per iteration.
Exit status: 0 ok, 1 regression or missing workload, 2 usage error or unreadable report.
"""

import json
import subprocess
import sys


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            document = json.load(handle)
        results = document["results"]
        return {result["name"]: result for result in results}
    except (OSError, ValueError, KeyError, TypeError) as error:
        print("benchmarks: %s is not a benchmark report (%s)" % (path, error), file=sys.stderr)
        sys.exit(2)


def write(path, results):
    ordered = [results[name] for name in sorted(results)]
    with open(path, "w", encoding="utf-8") as handle:
        json.dump({"results": ordered}, handle, indent=2, sort_keys=True)
        handle.write("\n")


def merge(output, inputs):
    best = {}
    for path in inputs:
        for name, result in load(path).items():
            if name not in best or result["minimum"] < best[name]["minimum"]:
                best[name] = result
    write(output, best)
    print("benchmarks: %d workloads, the best of %d launch%s" % (len(best), len(inputs), "" if len(inputs) == 1 else "es"))
    return 0


def compare(baseline_path, report_path, allow):
    baseline, report = load(baseline_path), load(report_path)
    width = max([len(name) for name in list(baseline) + list(report)] + [8])
    failures = 0
    print("benchmarks: %-*s  %12s  %12s  %8s" % (width, "workload", "baseline ns", "measured ns", "change"))
    for name in sorted(set(baseline) | set(report)):
        base, measured = baseline.get(name), report.get(name)
        if base is None:
            print("benchmarks: %-*s  %12s  %12.1f  %8s  not in the baseline" % (width, name, "", measured["minimum"], ""))
            continue
        if measured is None:
            print("benchmarks: %-*s  %12.1f  %12s  %8s  FAIL: not measured" % (width, name, base["minimum"], "", ""))
            failures += 1
            continue
        change = (measured["minimum"] - base["minimum"]) / base["minimum"] if base["minimum"] > 0 else 0.0
        verdict = ""
        if base["minimum"] > 0 and measured["minimum"] > base["minimum"] * (1 + allow):
            verdict = "  FAIL: slower by more than %.0f %%" % (allow * 100)
            failures += 1
        print("benchmarks: %-*s  %12.1f  %12.1f  %+7.1f %%%s" % (width, name, base["minimum"], measured["minimum"], change * 100, verdict))
    if failures:
        print("benchmarks: FAILED: %d workload%s regressed or went unmeasured (PERF-1)" % (failures, "" if failures == 1 else "s"))
        return 1
    print("benchmarks: no workload is more than %.0f %% slower than its baseline" % (allow * 100))
    return 0


def runner():
    def sysctl(name):
        try:
            return subprocess.run(["sysctl", "-n", name], capture_output=True, text=True).stdout.strip()
        except OSError:
            return ""
    parts = [sysctl("hw.model"), sysctl("machdep.cpu.brand_string"), sysctl("hw.ncpu") + " cores"]
    print(" · ".join(part for part in parts if part.strip(" cores")))
    return 0


def main(arguments):
    if len(arguments) >= 3 and arguments[0] == "merge":
        return merge(arguments[1], arguments[2:])
    if arguments[:1] == ["runner"] and len(arguments) == 1:
        return runner()
    if arguments[:1] == ["compare"]:
        baseline = report = None
        allow = 0.10
        rest = arguments[1:]
        while rest:
            option = rest.pop(0)
            if option == "--baseline" and rest:
                baseline = rest.pop(0)
            elif option == "--report" and rest:
                report = rest.pop(0)
            elif option == "--allow" and rest:
                try:
                    allow = float(rest.pop(0))
                except ValueError:
                    break
            else:
                baseline = None
                break
        if baseline and report and allow >= 0:
            return compare(baseline, report, allow)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
