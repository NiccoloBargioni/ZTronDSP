#!/bin/bash
# Self-test of the process files and of Scripts/ledger.sh (WP-008).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
P="$ROOT/Docs/Process"
LEDGER="$ROOT/Scripts/ledger.sh"
make_scratch process-test
L="$SCRATCH/ledger.md"

holds() {   # <file> <field> …: every field of §11 that the template has to carry
    local file="$1" missing=""; shift
    for field in "$@"; do grep -q -F -- "$field" "$P/templates/$file" || missing="$missing [$field]"; done
    if [ -z "$missing" ]; then pass "templates/$file carries its fields"; else fail "templates/$file lacks:$missing"; fi
}
set_cell() { # <id> <column> <value>: writes one cell of the scratch ledger
    python3 - "$L" "$1" "$2" "$3" <<'PY'
import sys
path, identifier, column, value = sys.argv[1:5]
lines = open(path, encoding="utf-8").read().split("\n")
header = None
for index, line in enumerate(lines):
    if line.startswith("| ID |"):
        header = [cell.strip() for cell in line.strip().strip("|").split("|")]
    elif header and line.startswith("| %s |" % identifier):
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        cells[header.index(column)] = value
        lines[index] = "| " + " | ".join(cells) + " |"
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
}
finish_package() { # <id>: fills in everything a Done row needs
    set_cell "$1" Status Done; set_cell "$1" Implementer agent-i; set_cell "$1" "Verifier A" agent-a; set_cell "$1" "Verifier B" agent-b
    set_cell "$1" "Time (min)" 25; set_cell "$1" Revision 0a1b2c3; set_cell "$1" "Report A" "reports/$1-A.md"; set_cell "$1" "Report B" "reports/$1-B.md"
    set_cell "$1" "Fix cycles" 0; set_cell "$1" Backlog none
    mkdir -p "$SCRATCH/reports"; : > "$SCRATCH/reports/$1-A.md"; : > "$SCRATCH/reports/$1-B.md"
}

echo "process files"
holds brief.md "Goal" "Dependencies" "Lenses" "Tag" "Acceptance" "Specification sections to read" "Files to create or change" "Out of scope" "30 minutes" "minute 20" "currency check" "stability note"
holds ledger-row.md "Status" "Implementer" "Verifier A" "Verifier B" "Time (min)" "Revision" "Report A" "Report B" "Fix cycles" "Currency check" "Stability note" "Backlog" \
    "Ready" "Implementing" "Verifying" "Fixing" "Done" "Paused" "Escalated" "Retired" "Definition of done"
holds verifier-report.md "Lens" "Verifier" "Revision reviewed" "Fix cycle" "Verdict" "\`pass\` or \`blocking\`" "Checklist item" "Location" "Evidence" "Severity" \
    "What was received (VER-2)" "Acceptance checks run by the verifier (VER-3)" "Re-verification (FIX-1)" "Change requests filed (FIX-4)" \
    "**N —" "**R —" "**A —" "**T —" "**V —" "**S —"
holds change-request.md "Status" "Kind" "Raised by" "Raised on" "Packages paused" "Approved by" "Approved on" "## What" "## Why" "## Evidence" "## Sections affected" \
    "For a split (§11.7)" "Open blocking findings carried (FIX-3)" "Owner's decision"
holds stability-note.md "Register row" "Currency check (§7.3)" "Date" "Registered source confirmed" "Consulted" "Outcome" "## Hazard" "## Bound or measured behaviour" "## Mitigation" "## Stress test" "Precision"

# The registers were created empty (WP-008). Three must stay empty unless a change request
# says otherwise; the other two fill as the code grows, and the lint keeps each of them equal
# to the code in both directions, so here it is enough that they exist and hold a table.
for register in approvals.md mutable-by-design.md open-declarations.md; do
    if [ ! -f "$P/$register" ]; then fail "the register $register exists"; continue; fi
    rows="$(awk '/^\|/ { n++ } END { print n + 0 }' "$P/$register")"
    if [ "$rows" -eq 2 ]; then pass "the register $register exists and is empty"; else fail "the register $register exists and is empty ($((rows - 2)) rows)"; fi
done
for register in unchecked-sendable.md shader-coverage.md; do
    if [ ! -f "$P/$register" ]; then fail "the register $register exists"; continue; fi
    rows="$(awk '/^\|/ { n++ } END { print n + 0 }' "$P/$register")"
    if [ "$rows" -ge 2 ]; then pass "the register $register exists and holds its table"; else fail "the register $register exists and holds its table"; fi
done
for folder in reports changes; do
    if [ -d "$P/$folder" ]; then pass "Docs/Process/$folder exists"; else fail "Docs/Process/$folder exists"; fi
done

echo "ledger"
expect_status 0 "the committed ledger is consistent with §12 and §11" "$LEDGER" --check
# One row for each package of §12. A split recorded here (§11.7) adds a row for each part,
# directly under the package it retires; the check above vouches for those, so they are not
# counted (a part that §12 itself lists has no retired row above it, and is).
rows="$(awk -F'|' '
    { gsub(/\\\|/, "") }
    /^\| WP-/ { id = $2; gsub(/ /, "", id); status = $7; gsub(/ /, "", status); order[++n] = id; state[id] = status }
    END {
        for (k = 1; k <= n; k++) {
            base = substr(order[k], 1, 6)
            if (order[k] != base && state[base] == "Retired") continue
            count++
        }
        print count + 0
    }' "$P/ledger.md")"
if [ "$rows" -eq 289 ]; then pass "it has one row for each of the 289 packages, the parts of a split aside"; else fail "it has one row for each of the 289 packages, the parts of a split aside ($rows rows)"; fi
cp "$P/ledger.md" "$L"
expect_status 0 "re-deriving it changes nothing" "$LEDGER" --update --ledger "$L"
if cmp -s "$L" "$P/ledger.md"; then pass "… byte for byte"; else fail "… byte for byte" "$(diff "$P/ledger.md" "$L" | head -5)"; fi
# From here on the ledger is one derived afresh from §12: what the committed ledger records of
# the work done so far is not what these checks are about.
rm -f "$L"
expect_status 0 "a ledger is derived from §12 where there is none" "$LEDGER" --update --ledger "$L"
if grep -q '^| WP-001 .* | Ready |' "$L" && grep -q '^| WP-002 .* | Blocked-on-deps |' "$L" && grep -q '^| WP-422 .* | Awaiting-trigger |' "$L"; then
    pass "a package without dependencies is Ready, one with them is blocked, an OPT package waits for its trigger"
else
    fail "a package without dependencies is Ready, one with them is blocked, an OPT package waits for its trigger"
fi

finish_package WP-001
expect_status 0 "a finished package is kept by an update" "$LEDGER" --update --ledger "$L"
if grep -q '^| WP-001 .* | Done | agent-i | agent-a | agent-b | 25 | 0a1b2c3 |' "$L"; then pass "… with everything that was filled in"; else fail "… with everything that was filled in" "$(grep '^| WP-001 ' "$L")"; fi
if grep -q '^| WP-002 .* | Ready |' "$L" && grep -q '^| WP-101 .* | Ready |' "$L" && grep -q '^| WP-108 .* | Blocked-on-deps |' "$L"; then
    pass "… and what depended only on it becomes Ready (WP-R4)"
else
    fail "… and what depended only on it becomes Ready (WP-R4)" "$(grep -E '^\| WP-(002|101|108) ' "$L" | cut -c1-160)"
fi
expect_status 0 "the updated ledger is consistent" "$LEDGER" --check --ledger "$L"

cp "$L" "$SCRATCH/good.md"
set_cell WP-001 Revision ""
expect_status 1 "a Done row without a revision is incomplete" "$LEDGER" --check --ledger "$L"
expect_contains "… and the check names the column" "WP-001 is Done but 'Revision' is empty (§11.8, item 6)"
cp "$SCRATCH/good.md" "$L"; set_cell WP-001 "Verifier B" agent-i
expect_status 1 "one actor in two roles is reported" "$LEDGER" --check --ledger "$L"
expect_contains "… with the rule" "WP-001: one actor holds two roles (§11.1)"
cp "$SCRATCH/good.md" "$L"; set_cell WP-001 "Fix cycles" 4
expect_status 1 "a fourth fix cycle is reported" "$LEDGER" --check --ledger "$L"
cp "$SCRATCH/good.md" "$L"; rm "$SCRATCH/reports/WP-001-B.md"
expect_status 1 "a Done row whose report does not exist is reported" "$LEDGER" --check --ledger "$L"
expect_contains "… by name" "Docs/Process/reports/WP-001-B.md does not exist"
: > "$SCRATCH/reports/WP-001-B.md"
cp "$SCRATCH/good.md" "$L"; set_cell WP-002 Status Finished
expect_status 1 "a status that §11.3 does not have is reported" "$LEDGER" --check --ledger "$L"
cp "$SCRATCH/good.md" "$L"; set_cell WP-003 Lenses "A, A"
expect_status 1 "a column that disagrees with §12 is reported" "$LEDGER" --check --ledger "$L"
expect_contains "… with both values" "WP-003: Lenses is 'A, A', §12 says 'T, A'"
expect_status 0 "… and an update puts it right" "$LEDGER" --update --ledger "$L"
cp "$SCRATCH/good.md" "$L"; set_cell WP-002 Status Blocked-on-deps
expect_status 1 "a computed status that is out of date is reported" "$LEDGER" --check --ledger "$L"
cp "$SCRATCH/good.md" "$L"; sed -i '' '/^| WP-005 /d' "$L"
expect_status 1 "a package without a row is reported" "$LEDGER" --check --ledger "$L"
expect_contains "… by name" "WP-005 has no row"

# A package that is Done and ALG owes its currency check and its stability note (WP-R5).
cp "$SCRATCH/good.md" "$L"; finish_package WP-528
expect_status 1 "an ALG package is not complete without its currency check and stability note" "$LEDGER" --check --ledger "$L"
expect_contains "… and both are named" "WP-528 is Done and ALG but 'Stability note' is empty (WP-R5)"
set_cell WP-528 "Currency check" "2026-11-15: still current"; set_cell WP-528 "Stability note" "Docs/Numerics/16.md"
expect_status 0 "… and is complete with them" "$LEDGER" --check --ledger "$L"

# A split (§11.7): the original is retired and its parts follow it.
cp "$SCRATCH/good.md" "$L"; set_cell WP-002 Status Retired
python3 - "$L" <<'PY'
import sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
index = next(i for i, line in enumerate(lines) if line.startswith("| WP-002 |"))
for suffix in ("b", "a"):
    cells = [cell.strip() for cell in lines[index].strip().strip("|").split("|")]
    cells[0], cells[5] = "WP-002" + suffix, "Ready"
    lines.insert(index + 1, "| " + " | ".join(cells) + " |")
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
expect_status 0 "the parts of a retired package are kept by an update" "$LEDGER" --update --ledger "$L"
if grep -q '^| WP-002a ' "$L" && grep -q '^| WP-002b ' "$L" && grep -q '^| WP-010 .* | Blocked-on-deps |' "$L"; then
    pass "… and what depended on it waits for all of its parts"
else
    fail "… and what depended on it waits for all of its parts" "$(grep -E '^\| WP-(002|002a|002b|010) ' "$L" | cut -c1-140)"
fi
expect_status 0 "… and the ledger with a split is consistent" "$LEDGER" --check --ledger "$L"
finish_package WP-002a; finish_package WP-002b
"$LEDGER" --update --ledger "$L" >/dev/null
if grep -q '^| WP-010 .* | Ready |' "$L"; then pass "… which becomes Ready when every part is Done"; else fail "… which becomes Ready when every part is Done" "$(grep -E '^\| WP-010 ' "$L" | cut -c1-140)"; fi
cp "$SCRATCH/good.md" "$L"; printf '| WP-777 | A row for nothing | — | A, T |  | Ready |  |  |  |  |  |  |  |  | n/a | n/a |  |\n' >> "$L"
expect_status 1 "a row that is neither a package nor a part of a retired one is reported" "$LEDGER" --check --ledger "$L"
expect_contains "… by name" "WP-777 is neither a package of §12 nor a part of a retired one"
finish
