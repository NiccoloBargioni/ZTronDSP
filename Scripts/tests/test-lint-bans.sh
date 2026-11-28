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

# The gallery's application (brief 61, B3): the UIKit boundary holds there with no bridge, and it
# does not `@testable import`; its hosted tests may do both (the trees hold unmarked cases of that).
# In ZTronDSPUI's code the layer's `contentsScale` is not named (SZ-2, CR-027); a comment may.
expect_status 1 "UIKit in the gallery's application fails part 1" "$LINT" --part 1 "$FIXTURES/part1"
expect_contains "… the import, and where it may not be" "[UB-1] import UIKit: no file in the gallery's application imports UIKit or AppKit"
expect_contains "… a UIKit name" "[UB-2] UIImpactFeedbackGenerator: a UIKit-style name (UI + capital) is not named in the gallery's application"
expect_contains "… a name UIKit declares" "[UB-2] NSTextAlignment is declared by UIKit and is not named in the gallery's application"
expect_lacks "… but not in its hosted tests" "GalleryTests/HostingSupport.swift"
expect_contains "the layer's scale read in ZTronDSPUI fails part 1" "DrawableScale.swift:6: [SZ-2] \`contentsScale\` is not named in the code of ZTronDSPUI"
expect_lacks "… a comment or a string that names it does not" "DrawableScale.swift:4:"
expect_status 1 "\`@testable import\` in the gallery's application fails part 3" "$LINT" --part 3 "$FIXTURES/part3"
expect_contains "… and says why" "Gallery/GalleryApp.swift:2: [EXT-1] \`@testable import\` is not used in the gallery's application"
expect_lacks "… but its hosted tests may" "GalleryTests/HostedScreenTests.swift"

# The stored `var`s of a public value type (IMM-1, IMM-2; WP-909): a public one whatever its
# setter, and one the module can set, each without a row in the register.
expect_status 1 "a stored \`var\` of a public value type fails part 4" "$LINT" --part 4 "$FIXTURES/part4"
expect_contains "… a public one, whatever its setter (IMM-2)" "Values/Frequency.swift:5: [IMM-2] \`Frequency.resolved\` is a public stored \`var\` of a value type: it is \`let\`, or it has an entry in Docs/Process/mutable-by-design.md"
expect_contains "… one the module can set (IMM-1)" "Values/Frequency.swift:8: [IMM-1] \`Frequency.scratch\` is a stored \`var\` of a public value type that the module can set: it is \`let\`, \`private(set)\` or \`fileprivate(set)\`, \`@usableFromInline\` when \`@inlinable\` code sets it (VIS-1), or it has an entry in Docs/Process/mutable-by-design.md"
expect_contains "… one of a type declared in a public extension" "[IMM-1] \`Frequency.Inside.value\` is a stored \`var\`"
expect_lacks "… but not one with a private setter" "\`Frequency.counted\`"
expect_lacks "… nor one that \`@inlinable\` code sets (VIS-1)" "\`Frequency.inlined\`"
expect_lacks "… nor a computed property with a setter" "\`Frequency.both\`"
expect_lacks "… nor one of a reference type" "\`Store.history\`"
expect_lacks "… nor one of an internal type" "\`Internal.value\`"

# The shaders are compiled by the build (DEP-4, brief 76): no production code makes a shader
# library from source, in Swift or in Objective-C, however the call is spread over lines; a
# comment or a string may name the call, and a test may make one (the trees hold unmarked cases).
expect_status 1 "a shader library made from source under Sources/ fails part 4" "$LINT" --part 4 "$FIXTURES/part4"
expect_contains "… and the message says what the build does instead" "Context/RuntimeShaders.swift:9: [DEP-4] \`makeLibrary(source:)\` compiles shader source when the package runs: the build compiles the .metal sources into default.metallib in the module bundle, which is loaded with makeDefaultLibrary(bundle: .module)"
expect_contains "… a call spread over two lines" "Context/RuntimeShaders.swift:18: [DEP-4]"
expect_contains "… the Objective-C spelling" "CZTronDSP/runtime_shaders.m:5: [DEP-4] \`newLibraryWithSource:\`"
expect_lacks "… but not a test that makes one" "StubLibraryTests.swift"
expect_lacks "… nor a comment that names the call" "RuntimeShaders.swift:4:"
expect_lacks "… nor a string" "RuntimeShaders.swift:6:"

expect_status 2 "an unknown part is a usage error" "$LINT" --part 5
expect_status 2 "a missing tree is a usage error" "$LINT" "$FIXTURES/absent"
expect_status 0 "the package itself is clean" "$LINT"
finish
