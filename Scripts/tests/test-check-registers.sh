#!/bin/bash
# Self-test of Scripts/check-registers.sh (WP-905a…d): the fixture under Tests/Fixtures/Registers/Good
# passes; each way an audit table can be wrong fails with its sentence; then the package's own
# audit of the registers (Docs/Numerics/register-audit-*.md) is checked against the specification.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
CHECK="$ROOT/Scripts/check-registers.sh"
GOOD="$ROOT/Tests/Fixtures/Registers/Good"
make_scratch registers-test
T="$SCRATCH/tree"
AUDIT="$T/Numerics/register-audit-2026-11.md"

fresh() { rm -rf "$T"; cp -R "$GOOD" "$T"; }
run_check() { "$CHECK" --root "$T" --spec "$T/spec.md" --numerics "$T/Numerics" "$@"; }
edit() { # <file> <old> <new>: replaces one occurrence, which must exist
    python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1:4]
text = open(path, encoding="utf-8").read()
assert old in text, (path, old)
open(path, "w", encoding="utf-8").write(text.replace(old, new, 1))
PY
}
broken() { # <name> <expected text> <file> <old> <new>
    fresh; edit "$3" "$4" "$5"
    expect_status 1 "$1" run_check
    expect_contains "$1: says why" "$2"
}

echo "check-registers"
fresh
expect_status 0 "the fixture's audit holds" run_check
expect_contains "it says what it checked" "registers: 3 rows, 3 ALG packages, 3 notes (1 supplementary), 4 tests and 4 files checked: OK"

broken "a row is missing" "2 rows, expected 3 (one per row of §7.2)" "$AUDIT" \
    "| 2 | Framing | WP-002 | \`two.md\` | not searched on 2026-11-21 | true | \`Tests/ThingTests.swift\`: \`ThingTests.alsoWorks\` | M2 killed | none in arithmetic | none |"$'\n' ""
broken "an empty cell" "row 2, the cell 'Mutations' is empty" "$AUDIT" "| M2 killed |" "|  |"
broken "a cell left pending" "row 3, the cell 'Open' is empty" "$AUDIT" "| open: A-1 |" "| pending |"
broken "a currency check without a date" "row 1, the currency check carries no date" "$AUDIT" "| 2026-11-21: current | true;" "| current | true;"
broken "a date that does not exist" "the currency date 2026-02-30 does not exist" "$AUDIT" "| 2026-11-21: current | true;" "| 2026-02-30: current | true;"
broken "a file that does not exist" "names Sources/Gone.swift, which does not exist" "$AUDIT" "\`Sources/Thing.swift\`" "\`Sources/Gone.swift\`"
broken "a test the file does not declare" "names the test gone, which Tests/ThingTests.swift does not declare" "$AUDIT" "\`works\` | M1" "\`gone\` | M1"
broken "a test of a suite the file does not declare" "names the test OtherTests.alsoWorks" "$AUDIT" "\`ThingTests.alsoWorks\`" "\`OtherTests.alsoWorks\`"
broken "a test named without its file" "are not named with one file" "$AUDIT" "\`Tests/ThingTests.swift\`: \`works\` | M1" "\`works\` | M1"
broken "an ALG package in two rows" "the ALG package WP-001 is in rows 1, 2; it belongs in exactly one" "$AUDIT" "| Framing | WP-002 |" "| Framing | WP-002, WP-001 |"
broken "an ALG package in no row" "the ALG package WP-004 is in no row" "$AUDIT" "| IIR filtering | WP-004 |" "| IIR filtering | none |"
broken "a package that is not ALG" "row 3 lists WP-003, which §12 does not tag ALG" "$AUDIT" "| IIR filtering | WP-004 |" "| IIR filtering | WP-004, WP-003 |"
broken "a note named by no row" "the note extra.md is named by no row and not listed as supplementary" "$AUDIT" "**Supplementary notes.** \`extra.md\`" "**Supplementary notes.** none"
broken "a row without a note" "row 2 names no stability note (NUMS-1)" "$AUDIT" "| \`two.md\` |" "| two |"
broken "a note that does not exist" "row 3 names the note four.md, which is not in Numerics" "$AUDIT" "\`three.md\`, \`one.md\`" "\`three.md\`, \`one.md\`, \`four.md\`"
broken "an operation that is not the register's" "row 2 is 'Framing' in §7.2, not 'Framing of frames'" "$AUDIT" "| 2 | Framing |" "| 2 | Framing of frames |"
broken "a row without its twin in §7.5" "row 3 has no twin in the stability register §7.5 (NUMS-1)" "$T/spec.md" "| 3 | IIR filtering | Poles near 1 |" "| 9 | IIR filtering | Poles near 1 |"
broken "a header with a column missing" "the header is" "$AUDIT" "| Precision | Open |" "| Open |"
broken "rows out of order" "row number 3, expected 2" "$AUDIT" "| 2 | Framing |" "| 3 | Framing |"

fresh; rm "$T/Numerics/register-audit-2026-11.md"
expect_status 1 "no audit at all" run_check
expect_contains "no audit at all: says so" "there is no Numerics/register-audit-*.md"
expect_status 2 "a usage error" "$CHECK" --nonsense

# The package's own audit, against the package's specification.
expect_status 0 "the package's audit of the registers holds" "$CHECK"
expect_contains "it covers the 24 rows of §7.2" "registers: 24 rows,"

finish
