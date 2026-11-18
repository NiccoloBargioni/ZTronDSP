#!/bin/bash
# The coverage gate (WP-003; COV-1…COV-6; CI gate 6 of §10.3).
#
#   Scripts/coverage-gate.sh --report FILE [--report FILE]… [--mode MODE]… [--root DIR] [FILE …]
#   Scripts/coverage-gate.sh --xcresult BUNDLE [--mode MODE]…        reads the bundle with xccov itself
#
# A report is xccov's JSON for a result bundle of `xcodebuild test -enableCodeCoverage YES`:
#   xcrun xccov view --report  --json <bundle>.xcresult     totals per file
#   xcrun xccov view --archive --json <bundle>.xcresult     every line (exact for coverage:ignore marks)
# Either shape is accepted, and several reports are merged (a device run with a simulator run).
#
# Modes (default: aggregate and per-target):
#   aggregate       all production targets together                    ≥ 97.5 %   (COV-2)
#   per-target      each production target                             ≥ 95 %     (COV-2)
#   changed-files   each file named after the options, or one per
#                   line on standard input when none is named          ≥ 97.5 %   (COV-3)
#
# Outside the denominator (COV-4, COV-6): tests, Examples, benchmarks, ZTronDSPTesting,
# CZTronDSPTesting, Metal shaders, and lines marked `// coverage:ignore(<reason>)`, whose total
# stays below 0.5 % of the production lines.
# Exit status: 0 pass, 1 fail, 2 usage error, 3 nothing to measure.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

arguments=()
temporary=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--xcresult" ] && [ $# -ge 2 ]; then
        bundle="$2"; shift 2
        if [ ! -d "$bundle" ]; then echo "coverage-gate: no result bundle at $bundle" >&2; exit 2; fi
        if [ -z "$temporary" ]; then
            temporary="$(mktemp -d "${TMPDIR:-/tmp}/ztd-coverage.XXXXXX")" || { echo "coverage-gate: cannot make a scratch folder" >&2; exit 2; }
        fi
        name="$temporary/$(basename "$bundle")"
        xcrun xccov view --report --json "$bundle" > "$name.report.json" || { echo "coverage-gate: xccov cannot read $bundle" >&2; exit 2; }
        arguments+=(--report "$name.report.json")
        # The per-line view makes the handling of coverage:ignore marks exact. Older result bundles lack it.
        if xcrun xccov view --archive --json "$bundle" > "$name.lines.json" 2>/dev/null && [ -s "$name.lines.json" ]; then
            arguments+=(--report "$name.lines.json")
        fi
    else
        arguments+=("$1"); shift
    fi
done

python3 "$ROOT/Scripts/lib/coverage_gate.py" ${arguments[@]+"${arguments[@]}"}
status=$?
case "$temporary" in */ztd-coverage.??????) rm -rf "$temporary" ;; esac
exit $status
