#!/bin/bash
# Self-test of Scripts/compile-fixtures.sh (WP-009).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/CompileFixtures"
HARNESS="$ROOT/Scripts/compile-fixtures.sh"

echo "compile-fixtures"
expect_status 0 "valid fixtures that compile and invalid ones that fail with their sentence pass" \
    "$HARNESS" --no-modules --valid "$F/behaves/valid" --invalid "$F/behaves/invalid"
expect_contains "… and are counted" "2 valid fixtures compile, 1 invalid fixtures fail with their sentences"

expect_status 1 "a valid file filed as invalid fails the run" "$HARNESS" --no-modules --invalid "$F/valid-filed-as-invalid/invalid"
expect_contains "… and says why" "Compiles.swift: it is filed as invalid and compiles"
expect_status 1 "an invalid file filed as valid fails the run" "$HARNESS" --no-modules --valid "$F/invalid-filed-as-valid/valid"
expect_contains "… and says why" "DoesNotCompile.swift: it is filed as valid and does not compile"
expect_contains "… and shows the compiler's words" "cannot convert value of type 'String' to specified type 'Int'"
expect_status 1 "a wrong sentence fails the run" "$HARNESS" --no-modules --invalid "$F/wrong-sentence/invalid"
expect_contains "… and names the sentence" "it fails, but not with the sentence: MelScale needs a linear-frequency spectrum of magnitudes or powers"
expect_status 1 "an invalid file without a sentence fails the run" "$HARNESS" --no-modules --invalid "$F/no-sentence/invalid"
expect_contains "… and says why" "it is filed as invalid and names no sentence"
expect_status 1 "every sentence of a file must appear" "$HARNESS" --no-modules --invalid "$F/two-sentences/invalid"
expect_contains "… and the missing one is named" "not with the sentence: cannot find 'undefinedName' in scope"
expect_status 1 "one misbehaving fixture among good ones fails the run" \
    "$HARNESS" --no-modules --valid "$F/behaves/valid" --invalid "$F/wrong-sentence/invalid" --jobs 1
expect_contains "… and the tally says so" "1 of 3 fixtures misbehave"
expect_status 0 "a file's flags reach the compiler" "$HARNESS" --no-modules --valid "$F/flags/valid"
expect_status 3 "no fixture at all is its own status" "$HARNESS" --no-modules --valid "$F/empty/valid"
expect_status 2 "a missing folder is a usage error" "$HARNESS" --no-modules --valid "$F/absent"
expect_status 2 "an unknown option is a usage error" "$HARNESS" --everything

PRODUCTS="$("$ROOT/Scripts/xc.sh" products)"
if [ -d "$PRODUCTS/ZTronDSPCore.swiftmodule" ]; then
    expect_status 0 "the package's own fixtures behave against the last build" "$HARNESS"
    expect_status 1 "a module that cannot be loaded is reported as the harness's problem" \
        env ZTD_DERIVED="$ROOT/.build/no-such-build" "$HARNESS" --valid "$ROOT/Tests/CompileFixtures/valid" --no-modules
    expect_contains "… not as the fixture's" "a module could not be loaded"
else
    echo "  SKIP  the package's own fixtures: there is no build at $PRODUCTS (run Scripts/xc.sh build)"
fi
finish
