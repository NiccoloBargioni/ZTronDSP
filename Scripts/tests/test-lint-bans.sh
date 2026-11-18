#!/bin/bash
# Self-test of Scripts/lint-bans.sh (WP-002, WP-010, WP-011, WP-012).
#
# A fixture tree under Tests/Fixtures/Lint marks every line the lint has to report with a
# trailing comment `// !! RULE [RULE …]`; findings on files that cannot carry a comment are
# listed in the tree's expected.txt. The lint must report exactly those, no more and no fewer.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
FIXTURES="$ROOT/Tests/Fixtures/Lint"
LINT="$ROOT/Scripts/lint-bans.sh"

expected_of() {   # prints `path:line: [RULE]` for every marker and every line of expected.txt
    ( cd "$1" && grep -rn -E '//[[:space:]]*!![[:space:]]' --include='*.swift' --include='*.c' --include='*.h' --include='*.m' --include='*.metal' . 2>/dev/null \
        | sed -E 's|^\./||' \
        | while IFS= read -r line; do
              location="${line%%:*}"; rest="${line#*:}"; number="${rest%%:*}"
              rules="${line##*!!}"
              for rule in $rules; do printf '%s:%s: [%s]\n' "$location" "$number" "$rule"; done
          done
      [ -f expected.txt ] && grep -v -E '^(#|$)' expected.txt )
    return 0
}

reported_of() {   # reduces the lint's output to `path:line: [RULE]`
    printf '%s\n' "$1" | sed -n -E 's/^(.+:[0-9]+: \[[A-Z0-9-]+\]).*$/\1/p'
}

check_tree() {    # <tree> <name> [lint arguments …]
    local tree="$1" name="$2"; shift 2
    local output status expected reported
    output="$("$LINT" "$@" "$FIXTURES/$tree" 2>&1)"; status=$?
    expected="$(expected_of "$FIXTURES/$tree" | sort)"
    reported="$(reported_of "$output" | sort)"
    if [ -z "$expected" ]; then
        if [ "$status" -eq 0 ] && [ -z "$reported" ]; then pass "$name"; else fail "$name (exit $status)" "$output"; fi
        return
    fi
    if [ "$status" -ne 1 ]; then fail "$name (exit $status, expected 1)" "$output"; return; fi
    if [ "$expected" = "$reported" ]; then
        pass "$name ($(printf '%s\n' "$expected" | wc -l | tr -d ' ') findings)"
    else
        fail "$name" "$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$reported") | sed -e 's/^</missing   /' -e 's/^>/unexpected/')"
    fi
}

echo "lint-bans"
check_tree clean "the clean tree passes all four parts"
for part in 1 2 3 4; do check_tree clean "the clean tree passes part $part" --part "$part"; done
check_tree registered "registered exceptions are accepted"

check_tree part1 "part 1 reports every seeded UIKit-boundary violation" --part 1
check_tree part2 "part 2 reports every seeded hot-path and source-type violation" --part 2
check_tree part3 "part 3 reports every seeded approval, SwiftUI-boundary and hidden-channel violation" --part 3
check_tree part4 "part 4 reports every seeded configuration name, setter, open, Sendable and shader violation" --part 4
check_tree registers-invalid "register rows without an approved change request, a reason or a match are reported" --part 3 --part 4

# A part reports only its own rules.
expect_status 0 "part 2 finds nothing in the part 1 tree" "$LINT" --part 2 "$FIXTURES/part1"
expect_status 0 "part 1 finds nothing in the part 3 tree" "$LINT" --part 1 "$FIXTURES/part3"

# The messages say what the rule asks for.
expect_status 1 "the CR-002 rule fails the run" "$LINT" --part 2 "$FIXTURES/part2"
expect_contains "the for-in message names the reason and CR-002" "at -Onone the loop allocates on every iteration, which breaks the allocation audit in Debug builds; write a \`while\` loop (CR-002)"
expect_status 1 "an allow-list entry without an approved change request fails" "$LINT" --part 3 "$FIXTURES/registers-invalid"
expect_contains "… because its change request is not approved" "CR-008 is 'Proposed', not Approved"
expect_contains "… or does not exist" "Docs/Process/changes/CR-404.md does not exist"
expect_contains "… or names no change request" "it names no change request (CR-nnn)"
expect_contains "… or is approved without a date" "CR-010 carries no date under 'Approved on'"
expect_contains "… or is approved by nobody" "CR-011 names nobody under 'Approved by'"
expect_contains "a stale allow-list entry is reported" "matches no code"

expect_status 2 "an unknown part is a usage error" "$LINT" --part 5
expect_status 2 "a missing tree is a usage error" "$LINT" "$FIXTURES/absent"
expect_status 0 "the package itself is clean" "$LINT"
finish
