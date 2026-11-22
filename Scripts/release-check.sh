#!/bin/bash
# The release checklist of 0.1.0 (WP-906), on one machine. Docs/Release/0.1.0-checklist.md names
# every item, the command that proves it and the last line that command prints; this script runs,
# in that order, every item that can be run here, and says of each what it gave.
#
#   Scripts/release-check.sh                every item, in order; exit 0 only when every item passed
#   Scripts/release-check.sh --allow-open   exit 0 when no item failed, though some are open
#   Scripts/release-check.sh --list         each item and the command that proves it; nothing runs
#   Scripts/release-check.sh --keep-going   accepted, and what it always does: every item runs,
#                                           whatever the items before it gave
#
# Each item ends in one line:
#   PASS                  the command proved it
#   FAIL                  it did not, or it could not run here; a skip that this machine could
#                         close is a failure too (the gates run under --strict)
#   OPEN (device)         it needs a run on a physical device, which no simulator replaces
#   OPEN (owner)          it needs a decision or an act of the owner
#   OPEN (not installed)  it needs a simulator runtime or a tool that this machine lacks
#
# The items, in order (the checklist has the same names):
#   gate-1 … gate-9   the CI gates of §10.3, each `Scripts/ci.sh --strict --gate N` (gate 5 with
#                     --matrix --tsan), read from ci.sh's summary line of the gate
#   self-tests, function-effects, perf-annotations, spec-crosscheck, docs-build,
#   golden-reproduce, gallery-ui, register-audit, registers
#                     beside the gates: the scripts' self-tests with the slow ones, the checks of
#                     the hot paths that no gate runs, the specification's cross-check, the
#                     documentation build, the golden vectors made again by the pinned oracles,
#                     the gallery's UI tests on the matrix, the audit of the algorithm and
#                     stability registers dated in the release month, the registers of
#                     Docs/Process against the code
#   ledger, ledger-done
#                     the ledger consistent with §12 and §11, and every row Done
#   plat3-ios-17.5, plat3-ios-18, plat3-ios-26, plat3-ios-27.0, plat3-ios-15
#                     the run-time matrix of PLAT-3: each simulator runtime run by gate 5 or not
#                     installed, read from gate 5's log; the iOS 15 device, read from the ledger
#   device-WP-338 … device-WP-611d
#                     the device runs, read from the ledger: Done, or open
#   change-requests   every change request decided: none Proposed
#   changelog, readme, clean-tree, tag
#                     what a tag of 0.1.0 needs, since Package.swift carries no version: the
#                     entry of CHANGELOG.md with its date, the README's install snippet if there
#                     is a README, a tree equal to HEAD from the start of the run to its end, and
#                     no tag 0.1.0 on another commit
#
# A command passes on exit status 0, except where a script exits 0 though it skipped something:
# Scripts/tests/run-all.sh (a check skipped) and Scripts/golden.sh --reproduce (a generator whose
# oracle is not installed) are read for their skips, which are open or failed as a gate's are.
#
# Every command runs in the package with its output in a log of its own, in the run's folder,
# which also holds summary.txt, the result lines so far. Before each command the free space of
# the package's disk is read: below the floor the command is not started and its item fails.
#
# Environment:
#   ZTD_RELEASE_LOGS          the run's folder (default .build/release-check/<date>-<time>)
#   ZTD_RELEASE_MONTH         the release month, YYYY-MM (default: this month): the month of the
#                             register audit (§7.3: WP-905 repeats the audit before every release)
#   ZTD_RELEASE_MIN_FREE_GIB  the floor of free space in GiB below which nothing starts (default 6)
#   ZTD_RELEASE_GIT, ZTD_RELEASE_DF
#                             stand-ins for git and df (the self-test)
#   Scripts/ci.sh's own variables reach it unchanged (ZTD_DERIVED, ZTD_DEVICE, …).
#
# Exit status: 0 every item passed (with --allow-open: none failed), 1 otherwise, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="0.1.0"
GIT="${ZTD_RELEASE_GIT:-git}"
DF="${ZTD_RELEASE_DF:-df}"
MONTH="${ZTD_RELEASE_MONTH:-$(date +%Y-%m)}"
FLOOR="${ZTD_RELEASE_MIN_FREE_GIB:-6}"
# The packages that §12 marks as runs on a device, and the crossovers that only a reference
# device can give (SEL-5).
DEVICE_RUNS="WP-338 WP-708 WP-903a WP-903b WP-904a WP-904b WP-611b WP-611c WP-611d"

allow_open=0; list=0
while [ $# -gt 0 ]; do
    case "$1" in
        --allow-open) allow_open=1 ;;
        --keep-going) ;;
        --list) list=1 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "release-check: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
case "$MONTH" in
    [0-9][0-9][0-9][0-9]-0[1-9]|[0-9][0-9][0-9][0-9]-1[0-2]) ;;
    *) echo "release-check: the release month is '$MONTH', not YYYY-MM" >&2; exit 2 ;;
esac
case "$FLOOR" in
    ''|*[!0-9]*) echo "release-check: the floor of free space is '$FLOOR', not a number of GiB" >&2; exit 2 ;;
esac
AUDIT="Docs/Numerics/register-audit-$MONTH.md"

# ---------------------------------------------------------------------------------------------
# The items: a name, what it proves, and the command (in parentheses: where the item is read
# from, when it runs nothing of its own)
# ---------------------------------------------------------------------------------------------
IDS=(); WHATS=(); COMMANDS=()
item() { IDS+=("$1"); WHATS+=("$2"); COMMANDS+=("$3"); }

item gate-1 "CI gate 1: build for simulator and device, warnings as errors; the gallery application in Release" "Scripts/ci.sh --strict --gate 1"
item gate-2 "CI gate 2: lint-bans, all four parts; the dependency graph" "Scripts/ci.sh --strict --gate 2"
item gate-3 "CI gate 3: compile fixtures and the order matrix" "Scripts/ci.sh --strict --gate 3"
item gate-4 "CI gate 4: the API digest; every public symbol documented with its threading contract" "Scripts/ci.sh --strict --gate 4"
item gate-5 "CI gate 5: tests on the simulator matrix, the gallery's hosted suites, the audit tests in Release, the Thread Sanitizer" "Scripts/ci.sh --strict --gate 5 --matrix --tsan"
item gate-6 "CI gate 6: coverage, aggregate and per target (COV-2)" "Scripts/ci.sh --strict --gate 6"
item gate-7 "CI gate 7: the golden manifest; the golden MATLAB scripts under GNU Octave" "Scripts/ci.sh --strict --gate 7"
item gate-8 "CI gate 8: the benchmark regression check on a pinned runner" "Scripts/ci.sh --strict --gate 8"
item gate-9 "CI gate 9: the external parity suite" "Scripts/ci.sh --strict --gate 9"
item self-tests "the self-tests of the scripts, the slow ones too" "Scripts/tests/run-all.sh --slow"
item function-effects "the C target's non-blocking functions, with function-effect errors (RT-1, E-32)" "Scripts/check-function-effects.sh"
item perf-annotations "the Swift leaf loops with the performance annotations on (RT-7, WP-015)" "Scripts/check-perf-annotations.sh"
item spec-crosscheck "the mechanical cross-check of the specification (§13.1)" "Scripts/spec-crosscheck.sh"
item docs-build "the documentation builds without a warning (WP-901b)" "Scripts/docs.sh --build"
item golden-reproduce "the pinned oracles make the committed golden vectors again" "Scripts/golden.sh --reproduce"
item gallery-ui "the gallery's UI tests on the simulator matrix (the nightly job)" "Scripts/ci.sh --strict --nightly --matrix"
item register-audit "the audit of the algorithm and stability registers, dated in the release month (§7.3, WP-905)" "Scripts/check-registers.sh --audit $AUDIT"
item registers "the registers against the code: approvals, mutable by design, open declarations, unchecked Sendable, shader coverage" "Scripts/lint-bans.sh --part 3 --part 4"
item ledger "the ledger consistent with §12 and §11" "Scripts/ledger.sh --check"
item ledger-done "every row of the ledger Done" "Scripts/ledger.sh --release"
item plat3-ios-17.5 "PLAT-3: the iOS 17.5 simulator" "(the log of gate-5)"
item plat3-ios-18 "PLAT-3: the newest iOS 18.x simulator" "(the log of gate-5)"
item plat3-ios-26 "PLAT-3: the newest iOS 26.x simulator" "(the log of gate-5)"
item plat3-ios-27.0 "PLAT-3: the iOS 27.0 simulator" "(the log of gate-5)"
item plat3-ios-15 "PLAT-3: the physical iOS 15 device (WP-338, WP-904a, WP-904b)" "(the ledger, from ledger-done)"
for package in $DEVICE_RUNS; do
    item "device-$package" "the device run of $package" "(the ledger, from ledger-done)"
done
item change-requests "every change request decided: none Proposed" "(Docs/Process/changes/CR-*.md)"
item changelog "CHANGELOG.md: the entry of $VERSION, with its release date" "(CHANGELOG.md)"
item readme "the README's install snippet names $VERSION, if there is a README" "(README.md)"
item clean-tree "the tree is HEAD from the start of the run to its end" "(git status --porcelain; git rev-parse HEAD)"
item tag "no tag $VERSION on another commit" "(git rev-parse refs/tags/$VERSION)"

if [ "$list" -eq 1 ]; then
    for index in "${!IDS[@]}"; do printf '%-18s %s\n' "${IDS[$index]}" "${COMMANDS[$index]}"; done
    exit 0
fi

# ---------------------------------------------------------------------------------------------
# Running and recording
# ---------------------------------------------------------------------------------------------
LOGS="${ZTD_RELEASE_LOGS:-$ROOT/.build/release-check/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$LOGS" || { echo "release-check: cannot make the folder $LOGS" >&2; exit 2; }
SUMMARY="$LOGS/summary.txt"
: > "$SUMMARY"
VERDICTS=(); LINES=()
# STARTED: the second (bash's SECONDS) at which the item's command began; empty for an item that
# runs no command. The first command begins at second 0.
LOG=""; STATUS=0; STARTED=""; GATE5_LOG=""; LEDGER_LOG=""; LEDGER_STATUS=""

shown() { case "$1" in "$ROOT"/*) printf '%s' "${1#"$ROOT"/}" ;; *) printf '%s' "$1" ;; esac; }

# record <index> <verdict> <message>: the one result line of the item.
record() {
    local minutes="" line
    if [ -n "$STARTED" ]; then minutes=" ($(( (SECONDS - STARTED + 30) / 60 )) min)"; fi
    line="$(printf '%-21s %-18s %s%s' "$2" "${IDS[$1]}" "$3" "$minutes")"
    VERDICTS[$1]="$2"; LINES[$1]="$line"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$SUMMARY"
}

last_line() { awk 'NF { line = $0 } END { print line }' "$1" | cut -c1-300; }

# room <index>: 0 when the disk has room for a command; otherwise the item fails, not started.
room() {
    local free
    free="$($DF -g "$ROOT" 2>/dev/null | tail -1 | awk '{ print $4 }')"
    case "$free" in ''|*[!0-9]*) return 0 ;; esac   # nothing to read: start, as a person would
    [ "$free" -ge "$FLOOR" ] && return 0
    record "$1" FAIL "not started: $free GiB free on the package's disk, below the floor of $FLOOR GiB (ZTD_RELEASE_MIN_FREE_GIB)"
    return 1
}

# execute <index>: runs the item's command in the package, into its log; STATUS is its exit status.
execute() {
    local command="${COMMANDS[$1]}"
    LOG="$LOGS/$(printf '%02d' $(($1 + 1)))-${IDS[$1]}.log"
    room "$1" || return 1
    printf 'release-check: %s: %s (log %s)\n' "${IDS[$1]}" "$command" "$(shown "$LOG")"
    # Split into words, never into file names.
    # shellcheck disable=SC2086
    ( set -f; cd "$ROOT" && exec $command ) > "$LOG" 2>&1 < /dev/null
    STATUS=$?
    return 0
}

# plain <index>: exit status 0 passes; the message is the command's last line.
plain() {
    if [ "$STATUS" -eq 0 ]; then record "$1" PASS "$(last_line "$LOG")"; else record "$1" FAIL "exit $STATUS: $(last_line "$LOG")"; fi
}

# joined: the lines of its input, joined with ", ".
joined() { awk 'NR > 1 { printf ", " } { printf "%s", $0 }'; }

# crosscheck <index>: Scripts/spec-crosscheck.sh ends in its notes; its tallies say the result.
crosscheck() {
    local counts
    counts="$(grep -E '^(DEFECTS|NOTES) \(' "$LOG" | sed -E 's/ — .*$//' | joined)"
    [ -n "$counts" ] || counts="$(last_line "$LOG")"
    if [ "$STATUS" -eq 0 ]; then record "$1" PASS "$counts"; else record "$1" FAIL "exit $STATUS: $counts"; fi
}

# self_tests <index>: Scripts/tests/run-all.sh exits 0 when a check was skipped (`  SKIP  …`). A
# skip for a tool that is not installed leaves the item open; any other skip (no build to read,
# say) is one this machine could close, and fails the item, as a skip fails a gate under --strict.
self_tests() {
    local line closable="" installed=0
    if [ "$STATUS" -ne 0 ]; then record "$1" FAIL "exit $STATUS: $(last_line "$LOG")"; return; fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            *"not installed"*) installed=1 ;;
            *) closable="${closable:+$closable; }$line" ;;
        esac
    done <<EOF_SKIPS
$(sed -n -E 's/^  SKIP  (.*)$/\1/p' "$LOG")
EOF_SKIPS
    if [ -n "$closable" ]; then record "$1" FAIL "$(last_line "$LOG"); this machine could close what was skipped: $closable"
    elif [ "$installed" -eq 1 ]; then record "$1" "OPEN (not installed)" "$(last_line "$LOG")"
    else record "$1" PASS "$(last_line "$LOG")"; fi
}

# golden_reproduce <index>: Scripts/golden.sh --reproduce exits 0 when it skipped a generator
# whose oracle is not installed; that generator made nothing again, so the item is open.
golden_reproduce() {
    local made exact skipped failures
    if [ "$STATUS" -ne 0 ]; then
        failures="$(grep -E '^golden: FAILED' "$LOG" | joined | cut -c1-300)"
        record "$1" FAIL "exit $STATUS: ${failures:-$(last_line "$LOG")}"; return
    fi
    made="$(grep -c -E '^golden: .+ reproduces its committed (files bit for bit|vectors within)' "$LOG")"
    exact="$(grep -c -E '^golden: .+ reproduces its committed files bit for bit$' "$LOG")"
    skipped="$(sed -n -E 's/^golden: SKIPPED ([^:]+): (.+) is not installed; nothing was reproduced$/\1 (\2)/p' "$LOG" | joined)"
    if [ -n "$skipped" ]; then
        record "$1" "OPEN (not installed)" "$made generator(s) made their files again; not run, for an oracle that is not installed: $skipped"
    elif [ "$made" -eq 0 ]; then
        record "$1" FAIL "no generator made its files again: $(last_line "$LOG")"
    else
        record "$1" PASS "$made generators made their committed files again, $exact of them bit for bit"
    fi
}

# skips <notes>: each skip that ci.sh names in a summary line's notes, one per line. The notes
# are joined with "; ", and each skip begins with "skipped: " (a skip's own words may hold "; ").
skips() {
    local rest="$1" message
    case "$rest" in "skipped: "*) rest="${rest#skipped: }" ;; *) rest="${rest#*; skipped: }"; [ "$rest" = "$1" ] && return 0 ;; esac
    while :; do
        message="${rest%%; skipped: *}"
        printf '%s\n' "$message"
        [ "$message" = "$rest" ] && break
        rest="${rest#*; skipped: }"
    done
}

# classify_ci <index> <label>: the item of a gate ("gate N") or of the nightly job ("nightly"),
# from ci.sh's summary line `ci: <label>  <name padded to 36>  <result>[ — <notes>]`.
classify_ci() {
    local summary result notes kinds="" closable="" message
    summary="$(awk -v prefix="ci: $2  " '
        /^ci: ===== summary =====$/ { on = 1; next }
        on && substr($0, 1, length(prefix)) == prefix { print substr($0, length(prefix) + 38); exit }
    ' "$LOG")"
    if [ -z "$summary" ]; then record "$1" FAIL "Scripts/ci.sh gave no summary line for $2 (exit $STATUS): $(last_line "$LOG")"; return; fi
    result="${summary%% — *}"; notes=""
    [ "$summary" != "$result" ] && notes="${summary#* — }"
    case "$result" in
        passed)
            if [ "$STATUS" -eq 0 ]; then record "$1" PASS "passed — $(last_line "$LOG")"; else record "$1" FAIL "passed by its summary, and ci.sh exited $STATUS"; fi
            return ;;
        FAILED) record "$1" FAIL "FAILED — $notes"; return ;;
        SKIPPED|"PASSED IN PART") ;;
        *) record "$1" FAIL "$summary"; return ;;
    esac
    while IFS= read -r message; do
        [ -n "$message" ] || continue
        case "$message" in
            *"simulator runtime of PLAT-3 is not installed"*|*"Octave is not installed"*)
                case ", $kinds, " in *", not installed, "*) ;; *) kinds="${kinds:+$kinds, }not installed" ;; esac ;;
            *"there is no baseline for this runner"*)
                case ", $kinds, " in *", owner, "*) ;; *) kinds="${kinds:+$kinds, }owner" ;; esac ;;
            *) closable="${closable:+$closable; }$message" ;;
        esac
    done <<EOF_SKIPS
$(skips "$notes")
EOF_SKIPS
    if [ -n "$closable" ]; then
        record "$1" FAIL "$result, and this machine could close what was skipped: $closable"
    elif [ -n "$kinds" ]; then
        record "$1" "OPEN ($kinds)" "$result — $notes"
    else
        record "$1" FAIL "$result, and no skip says why"
    fi
}

# plat3 <index> <runtime as ci.sh names it, "iOS 18.x"> <its version as an ERE, "18-[0-9]+">:
# what gate 5 did on the simulator of one runtime of the matrix (ztdsp-ci-<version>).
plat3() {
    local name tests hosted failures=""
    if [ -z "$GATE5_LOG" ] || [ ! -f "$GATE5_LOG" ]; then
        record "$1" FAIL "gate-5 did not run, so nothing says whether the $2 simulator ran the tests"; return
    fi
    if grep -q -F "SKIPPED: the $2 simulator runtime of PLAT-3 is not installed" "$GATE5_LOG"; then
        record "$1" "OPEN (not installed)" "the $2 simulator runtime of PLAT-3 is not installed on this machine"; return
    fi
    if grep -q -E "^ci: \[gate 5\] FAILED: no simulator could be made for the runtime com\.apple\.CoreSimulator\.SimRuntime\.iOS-$3\$" "$GATE5_LOG"; then
        record "$1" FAIL "the $2 runtime is installed, and no simulator could be made for it"; return
    fi
    name="$(sed -n -E "s/^ci: \[gate 5\] (ok|FAILED): tests in Debug on (ztdsp-ci-$3)\$/\2/p" "$GATE5_LOG" | head -1)"
    if [ -z "$name" ]; then
        record "$1" FAIL "gate 5 ran no test on a simulator of $2 (its log: $(shown "$GATE5_LOG"))"; return
    fi
    tests="tests in Debug on $name"
    hosted="the gallery's hosted suites on $name, with no known issue"
    grep -q -x -F "ci: [gate 5] FAILED: $tests" "$GATE5_LOG" && failures="the tests in Debug"
    grep -q -x -F "ci: [gate 5] FAILED: $hosted" "$GATE5_LOG" && failures="${failures:+$failures and }the gallery's hosted suites"
    if [ -n "$failures" ]; then
        record "$1" FAIL "installed; on $name $failures failed"
    elif grep -q -x -F "ci: [gate 5] ok: $hosted" "$GATE5_LOG"; then
        record "$1" PASS "installed; on $name the tests in Debug and the gallery's hosted suites passed"
    else
        record "$1" FAIL "installed; on $name the gallery's hosted suites did not run"
    fi
}

# The ledger as `Scripts/ledger.sh --release` lists it: every row that is not Done, one per line
# (`ledger: WP-nnn <status>`), then a tally; exit 0 when there is none.
ledger_read() {   # 0 when the listing is there to be read
    [ -n "$LEDGER_LOG" ] && [ -f "$LEDGER_LOG" ] || return 1
    [ "$LEDGER_STATUS" = 0 ] && return 0
    [ "$LEDGER_STATUS" = 1 ] && grep -q -E '^ledger: [0-9]+ of [0-9]+ rows are not Done' "$LEDGER_LOG"
}

ledger_status() {   # <package>: its status when it is not Done, else nothing
    sed -n -E "s/^ledger: $1 (.+)\$/\1/p" "$LEDGER_LOG" | head -1
}

has_row() {   # <package>: 0 when the ledger has a row for it (a package left out is no package Done)
    grep -q -E "^\| *$1 *\|" "$ROOT/Docs/Process/ledger.md" 2>/dev/null
}

classify_ledger() {
    local listed other
    LEDGER_LOG="$LOG"; LEDGER_STATUS="$STATUS"
    if ! ledger_read; then record "$1" FAIL "exit $STATUS: $(last_line "$LOG")"; return; fi
    if [ "$STATUS" -eq 0 ]; then record "$1" PASS "$(last_line "$LOG")"; return; fi
    listed="$(sed -n -E 's/^ledger: (WP-[0-9]{3}[a-z]?) .*$/\1/p' "$LOG")"
    other=""
    for package in $listed; do
        case " $DEVICE_RUNS " in *" $package "*) ;; *) other="$other $package" ;; esac
    done
    if [ -z "$other" ]; then
        record "$1" "OPEN (device)" "$(last_line "$LOG"): every one of them is a device run"
    else
        record "$1" FAIL "$(last_line "$LOG")"
    fi
}

device() {   # <index> <package>
    local status
    if ! ledger_read; then record "$1" FAIL "the ledger could not be read (ledger-done)"; return; fi
    if ! has_row "$2"; then record "$1" FAIL "$2 has no row in Docs/Process/ledger.md"; return; fi
    status="$(ledger_status "$2")"
    if [ -z "$status" ]; then
        record "$1" PASS "$2 is Done in the ledger"
    else
        record "$1" "OPEN (device)" "$2 is $status in the ledger: a run on a device (Docs/Release/0.1.0-checklist.md, the device runs)"
    fi
}

floor_device() {   # <index>: PLAT-3's physical iOS 15 device, which WP-338, WP-904a and WP-904b run on
    local package status open="" missing=""
    if ! ledger_read; then record "$1" FAIL "the ledger could not be read (ledger-done)"; return; fi
    for package in WP-338 WP-904a WP-904b; do
        if ! has_row "$package"; then missing="${missing:+$missing, }$package"; continue; fi
        status="$(ledger_status "$package")"
        [ -n "$status" ] && open="${open:+$open, }$package $status"
    done
    if [ -n "$missing" ]; then record "$1" FAIL "no row in Docs/Process/ledger.md for $missing"
    elif [ -z "$open" ]; then record "$1" PASS "WP-338, WP-904a and WP-904b are Done in the ledger"
    else record "$1" "OPEN (device)" "iOS 15 and 16 cannot be simulated on this host (E-17): $open"; fi
}

# field <change request> <field>: a value of the table at its top, `| Field | Value |`.
field() {
    awk -F'|' -v want="$2" 'NF >= 4 { key = $2; value = $3; gsub(/^ +| +$/, "", key); gsub(/^ +| +$/, "", value); if (key == want) { print value; exit } }' "$1"
}

change_requests() {   # <index>
    local file name status total=0 decided=0 proposed="" count=0 wrong=""
    for file in "$ROOT"/Docs/Process/changes/CR-*.md; do
        [ -f "$file" ] || continue
        total=$((total + 1)); name="$(basename "$file" .md)"
        status="$(field "$file" Status)"
        case "$status" in
            Proposed) proposed="${proposed:+$proposed, }$name"; count=$((count + 1)) ;;
            Approved)
                if [ -n "$(field "$file" "Approved by")" ] && [ -n "$(field "$file" "Approved on")" ]; then
                    decided=$((decided + 1))
                else
                    wrong="${wrong:+$wrong; }$name is Approved without the owner's name and date"
                fi ;;
            Rejected|Withdrawn) decided=$((decided + 1)) ;;
            *) wrong="${wrong:+$wrong; }$name has the status '$status', which is not one of the template's" ;;
        esac
    done
    if [ -n "$wrong" ]; then record "$1" FAIL "$wrong"
    elif [ -n "$proposed" ]; then record "$1" "OPEN (owner)" "$count of $total change requests are Proposed, for the owner to decide: $proposed"
    elif [ "$total" -eq 0 ]; then record "$1" PASS "there is no change request"
    else record "$1" PASS "every one of the $total change requests is decided"; fi
}

changelog() {   # <index>
    local file="$ROOT/CHANGELOG.md" heading pattern
    pattern="^## \[?$(printf '%s' "$VERSION" | sed 's/\./\\./g')\]?( |$)"
    if [ ! -f "$file" ]; then record "$1" FAIL "there is no CHANGELOG.md"; return; fi
    heading="$(grep -m1 -E "$pattern" "$file")"
    if [ -z "$heading" ]; then
        record "$1" FAIL "CHANGELOG.md has no entry for $VERSION (a heading \"## [$VERSION] - <date>\")"
    elif printf '%s' "$heading" | grep -q -E '[0-9]{4}-[0-9]{2}-[0-9]{2}'; then
        record "$1" PASS "CHANGELOG.md: $heading"
    else
        record "$1" "OPEN (owner)" "CHANGELOG.md: \"$heading\": the date goes in when the owner releases $VERSION"
    fi
}

readme() {   # <index>
    local file=""
    [ -f "$ROOT/README" ] && file="README"
    [ -f "$ROOT/README.md" ] && file="README.md"
    if [ -z "$file" ]; then
        record "$1" PASS "there is no README, so no install snippet names a version"
    elif grep -q -F "from: \"$VERSION\"" "$ROOT/$file"; then
        record "$1" PASS "$file: the install snippet names $VERSION"
    else
        record "$1" FAIL "$file has no install snippet that names $VERSION: .package(url: …, from: \"$VERSION\")"
    fi
}

START_HEAD=""
clean_tree() {   # <index>
    local head paths
    head="$($GIT -C "$ROOT" rev-parse HEAD 2>/dev/null)"
    $GIT -C "$ROOT" status --porcelain > "$LOGS/git-status-end.txt" 2>/dev/null
    paths="$(grep -c . "$LOGS/git-status-start.txt" 2>/dev/null)"
    if [ -z "$START_HEAD" ]; then
        record "$1" FAIL "there is no git commit here, so nothing could be tagged"
    elif [ "${paths:-0}" -gt 0 ]; then
        record "$1" FAIL "$paths path(s) differed from HEAD when the run began (git status --porcelain: $(shown "$LOGS/git-status-start.txt")): what was checked is in no commit"
    elif ! cmp -s "$LOGS/git-status-start.txt" "$LOGS/git-status-end.txt"; then
        record "$1" FAIL "the run changed the tree: $(tr '\n' ' ' < "$LOGS/git-status-end.txt" | cut -c1-200)"
    elif [ "$head" != "$START_HEAD" ]; then
        record "$1" FAIL "HEAD moved during the run, from $START_HEAD to $head"
    else
        record "$1" PASS "the tree was HEAD $START_HEAD throughout, with nothing uncommitted"
    fi
}

tag() {   # <index>
    local tagged
    tagged="$($GIT -C "$ROOT" rev-parse -q --verify "refs/tags/$VERSION^{commit}" 2>/dev/null)"
    if [ -z "$tagged" ]; then
        record "$1" PASS "$VERSION is not tagged yet: the tag goes on HEAD ${START_HEAD:-?} once this run passes, and not before"
    elif [ "$tagged" = "$START_HEAD" ]; then
        record "$1" PASS "$VERSION is HEAD $START_HEAD"
    else
        record "$1" FAIL "$VERSION already names $tagged, which is not HEAD ${START_HEAD:-?}"
    fi
}

# ---------------------------------------------------------------------------------------------

START_HEAD="$($GIT -C "$ROOT" rev-parse HEAD 2>/dev/null)"
$GIT -C "$ROOT" status --porcelain > "$LOGS/git-status-start.txt" 2>/dev/null
printf 'release-check: %s on %s, HEAD %s, release month %s; logs in %s\n' \
    "$VERSION" "$(date '+%Y-%m-%d %H:%M %Z')" "${START_HEAD:-none}" "$MONTH" "$(shown "$LOGS")"

for index in "${!IDS[@]}"; do
    STARTED=""
    case "${IDS[$index]}" in
        gate-*)
            STARTED=$SECONDS
            if execute "$index"; then
                [ "${IDS[$index]}" = gate-5 ] && GATE5_LOG="$LOG"
                classify_ci "$index" "gate ${IDS[$index]#gate-}"
            fi ;;
        gallery-ui)
            STARTED=$SECONDS
            if execute "$index"; then classify_ci "$index" nightly; fi ;;
        register-audit)
            if [ ! -f "$ROOT/$AUDIT" ]; then
                record "$index" FAIL "there is no audit of $MONTH, $AUDIT: WP-905 repeats it before every release (§7.3)"
            else
                STARTED=$SECONDS
                if execute "$index"; then plain "$index"; fi
            fi ;;
        ledger-done)
            STARTED=$SECONDS
            if execute "$index"; then classify_ledger "$index"; fi ;;
        self-tests)
            STARTED=$SECONDS
            if execute "$index"; then self_tests "$index"; fi ;;
        spec-crosscheck)
            STARTED=$SECONDS
            if execute "$index"; then crosscheck "$index"; fi ;;
        golden-reproduce)
            STARTED=$SECONDS
            if execute "$index"; then golden_reproduce "$index"; fi ;;
        plat3-ios-17.5) plat3 "$index" "iOS 17.5" "17-5" ;;
        plat3-ios-18) plat3 "$index" "iOS 18.x" "18-[0-9]+" ;;
        plat3-ios-26) plat3 "$index" "iOS 26.x" "26-[0-9]+" ;;
        plat3-ios-27.0) plat3 "$index" "iOS 27.0" "27-0" ;;
        plat3-ios-15) floor_device "$index" ;;
        device-*) device "$index" "${IDS[$index]#device-}" ;;
        change-requests) change_requests "$index" ;;
        changelog) changelog "$index" ;;
        readme) readme "$index" ;;
        clean-tree) clean_tree "$index" ;;
        tag) tag "$index" ;;
        *)
            STARTED=$SECONDS
            if execute "$index"; then plain "$index"; fi ;;
    esac
done

passed=0; failed=0; open=0
for index in "${!IDS[@]}"; do
    case "${VERDICTS[$index]:-FAIL}" in
        PASS) passed=$((passed + 1)) ;;
        OPEN*) open=$((open + 1)) ;;
        *) failed=$((failed + 1)) ;;
    esac
done
printf '\nrelease-check: ===== summary =====\n'
for index in "${!IDS[@]}"; do printf '%s\n' "${LINES[$index]:-FAIL                  ${IDS[$index]} recorded no result}"; done
printf 'release-check: %d items: %d passed, %d failed, %d open\n' "${#IDS[@]}" "$passed" "$failed" "$open" | tee -a "$SUMMARY"
if [ "$failed" -gt 0 ]; then
    echo "release-check: FAILED: $VERSION is not ready to tag" | tee -a "$SUMMARY"
    exit 1
elif [ "$open" -gt 0 ]; then
    if [ "$allow_open" -eq 1 ]; then
        echo "release-check: nothing failed; $open item(s) are open (--allow-open): $VERSION is not ready to tag" | tee -a "$SUMMARY"
        exit 0
    fi
    echo "release-check: $open item(s) are open: $VERSION is not ready to tag (--allow-open accepts open items)" | tee -a "$SUMMARY"
    exit 1
fi
echo "release-check: every item passed: $VERSION can be tagged on HEAD $START_HEAD" | tee -a "$SUMMARY"
exit 0
