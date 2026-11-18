#!/bin/bash
# Self-test of Scripts/coverage-gate.sh (WP-003).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/Coverage"
GATE="$ROOT/Scripts/coverage-gate.sh"

echo "coverage-gate"
expect_status 0 "reports above every threshold pass" "$GATE" --report "$F/report-pass.json" --report "$F/lines-pass.json" --root "$F/tree"
expect_contains "a file linked into two test bundles is counted once, at its better record" "aggregate      99.60 % (1254 of 1259 lines)"
expect_contains "tests, examples, generated code and the test product are outside the denominator" "ZTronDSPCore     99.82 % (1107 of 1109 lines)"
expect_contains "a target without executable lines is shown, and passes" "ZTronDSPMetal    no executable lines"

expect_status 1 "aggregate below 97.5 % fails" "$GATE" --report "$F/report-fail-aggregate.json" --no-sources
expect_contains "… and says so" "aggregate coverage is 96.00 %, below 97.50 % (COV-2)"
expect_lacks "… while every target is at 95 % or above" "below 95.00 %"
expect_status 0 "the per-target mode alone passes that report" "$GATE" --report "$F/report-fail-aggregate.json" --no-sources --mode per-target

expect_status 1 "a target below 95 % fails" "$GATE" --report "$F/report-fail-target.json" --no-sources
expect_contains "… and is named" "ZTronDSPDesign is at 90.00 %, below 95.00 % (COV-2)"
expect_lacks "… while the aggregate is above 97.5 %" "aggregate coverage is"
expect_status 0 "the aggregate mode alone passes that report" "$GATE" --report "$F/report-fail-target.json" --no-sources --mode aggregate

expect_status 1 "a target with code that the report does not hold fails" "$GATE" --report "$F/report-target-missing.json" --report "$F/lines-pass.json" --root "$F/tree"
expect_contains "… as not measured" "ZTronDSPDesign has code and the report holds none of it"

expect_status 3 "a report without production code is nothing to measure" "$GATE" --report "$F/report-nothing.json" --no-sources

# changed-files (COV-3)
expect_status 0 "changed files at 97.5 % or above pass" "$GATE" --report "$F/report-pass.json" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files \
    Sources/ZTronDSPCore/Toolkit.swift Sources/CZTronDSP/kernel.c Sources/ZTronDSPCore/Domains.swift Tests/ZTronDSPCoreTests/UnitsTests.swift README.md
expect_contains "a file of declarations has no executable lines" "Sources/ZTronDSPCore/Domains.swift                 no executable lines"
expect_contains "a test file is outside the denominator" "Tests/ZTronDSPCoreTests/UnitsTests.swift           outside the denominator"
expect_status 1 "a changed file below 97.5 % fails although its target passes" "$GATE" --report "$F/report-pass.json" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files \
    Sources/ZTronDSPDesign/Design.swift
expect_contains "… and is named" "Sources/ZTronDSPDesign/Design.swift is at 97.00 %, below 97.50 % (COV-3)"
LAST_OUTPUT="$(printf 'Sources/ZTronDSPDesign/Design.swift\n' | "$GATE" --report "$F/report-pass.json" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files 2>&1)"; LAST_STATUS=$?
if [ "$LAST_STATUS" -eq 1 ]; then pass "the list of changed files is read from standard input"; else fail "the list of changed files is read from standard input (exit $LAST_STATUS)" "$LAST_OUTPUT"; fi
expect_status 1 "a changed file that does not exist fails" "$GATE" --report "$F/report-pass.json" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files Sources/ZTronDSPCore/Gone.swift
expect_contains "… and is named" "Sources/ZTronDSPCore/Gone.swift does not exist"
expect_status 1 "a changed file with code in an unmeasured target fails" "$GATE" --report "$F/report-target-missing.json" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files \
    Sources/ZTronDSPDesign/Design.swift
expect_contains "… as not built with coverage" "has code and the report holds nothing of ZTronDSPDesign"

# coverage:ignore marks (COV-4 b), read against the per-line report
expect_status 0 "marked, unexecuted lines leave the denominator" "$GATE" --report "$F/lines-pass.json" --root "$F/tree" --mode changed-files Sources/ZTronDSPCore/Units.swift
expect_contains "… all three of them" "3 lines marked coverage:ignore (0.33 % of the production lines, below 0.50 %)"
expect_contains "… which leaves the file fully covered" "Sources/ZTronDSPCore/Units.swift                   100.00 % (9 of 9 lines)"
expect_status 1 "an unexecuted line that nothing marks still counts" "$GATE" --report "$F/lines-fail-file.json" --root "$F/tree" --mode changed-files Sources/ZTronDSPCore/Units.swift
expect_contains "… against its file" "Sources/ZTronDSPCore/Units.swift is at 88.89 %, below 97.50 % (COV-3)"
expect_status 0 "a second report that executes the line is merged line by line" "$GATE" --report "$F/lines-fail-file.json" --report "$F/lines-device.json" --root "$F/tree" \
    --mode changed-files Sources/ZTronDSPCore/Units.swift
expect_status 1 "marks at 0.5 % of the production lines or more fail" "$GATE" --report "$F/lines-cap.json" --root "$F/tree"
expect_contains "… with the share" "3 lines are marked coverage:ignore, 25.00 % of 12 production lines; COV-4 keeps them below 0.50 %"
expect_status 1 "marks cannot be read against totals" "$GATE" --report "$F/report-units-totals.json" --root "$F/tree"
expect_contains "… and the gate says what it needs" "Sources/ZTronDSPCore/Units.swift:5: coverage:ignore marks need the per-line report"
expect_status 1 "a mark in a file the report does not hold fails" "$GATE" --report "$F/report-pass.json" --root "$F/tree"
expect_contains "… because it excuses nothing" "Sources/ZTronDSPCore/Units.swift:10: a coverage:ignore mark in a file the report does not hold"
expect_status 1 "bad marks fail" "$GATE" --report "$F/lines-marks-bad.json" --root "$F/tree-marks-bad" --mode aggregate
expect_contains "a mark without a reason" "Sources/ZTronDSPCore/Marks.swift:2: \`// coverage:ignore()\` gives no reason"
expect_contains "a mark on an executed line" "Sources/ZTronDSPCore/Marks.swift:3: the mark excuses nothing"
expect_contains "a mark above a line that does not execute" "Sources/ZTronDSPCore/Marks.swift:4: the mark excuses nothing"

expect_status 2 "no report is a usage error" "$GATE" --mode aggregate
expect_status 2 "an unknown mode is a usage error" "$GATE" --report "$F/report-pass.json" --mode everything
expect_status 2 "something that is not an xccov report is a usage error" "$GATE" --report "$ROOT/Package.swift"
finish
