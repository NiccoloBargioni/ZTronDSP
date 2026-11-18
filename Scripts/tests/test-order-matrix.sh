#!/bin/bash
# Self-test of Scripts/order-matrix.sh (WP-328): with a fixture world of three domains and three
# stages, type-checked without the package's modules.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/OrderMatrix"
M="$ROOT/Scripts/order-matrix.sh"
make_scratch order-matrix
S="$SCRATCH"

echo "order-matrix"
if ! xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1; then
    echo "  SKIP  no iOS simulator SDK: the matrix cannot be type-checked here"
    finish
    exit $?
fi
TEMPLATE='func cell{cell}() {{ after({domain}.self, {stage}) }}'
matrix() {
    "$M" --no-modules --imports "" --prelude "$S/prelude.swift" --template "$TEMPLATE" --stages "$S/stages.txt" --domains "$F/domains.txt" \
        --swift "$S/Matrix.swift" --document "$S/Matrix.md" --sources "$F/sources" "$@"
}
cp "$F/prelude.swift" "$S/prelude.swift"; cp "$F/stages.txt" "$S/stages.txt"

expect_status 0 "the matrix of the fixture is generated" matrix
expect_contains "… and counted" "3 stages on 3 domains, 6 cells accepted"
if grep -q '"100",  // OnA' "$S/Matrix.swift" && grep -q '"110",  // OnAB' "$S/Matrix.swift" && grep -q '"111",  // Everywhere' "$S/Matrix.swift"; then
    pass "… with what the compiler says about each cell"
else
    fail "… with what the compiler says about each cell" "$(cat "$S/Matrix.swift")"
fi
if grep -q '| `OnAB` | ✓ | ✓ | · |' "$S/Matrix.md"; then pass "… and the table for people says the same"; else fail "… and the table for people says the same" "$(cat "$S/Matrix.md")"; fi
expect_status 0 "a matrix that is current passes the check" matrix --check

# A seeded disagreement: the compiler now accepts a cell the committed matrix refuses.
printf 'func after(_ domain: B.Type, _ stage: OnA) {}\n' >> "$S/prelude.swift"
expect_status 1 "a matrix that is no longer what the compiler says fails the check" matrix --check
expect_contains "… and says what to do" "is not what the compiler says today: run Scripts/order-matrix.sh"
if grep -q '"100",  // OnA' "$S/Matrix.swift"; then pass "… and the check writes nothing"; else fail "… and the check writes nothing"; fi
cp "$F/prelude.swift" "$S/prelude.swift"

# The list against the code.
printf 'Gone | Everywhere()\n' >> "$S/stages.txt"
expect_status 1 "a line that names no public stage fails" matrix --check
expect_contains "… by name" "Gone has a line"
grep -v '^OnAB' "$F/stages.txt" > "$S/stages.txt"
expect_status 1 "a public stage without a line fails" matrix --check
expect_contains "… by name, with its file" "OnAB (Tests/Fixtures/OrderMatrix/sources/Stages.swift) is a public stage with no line"
expect_lacks "a public type that is no stage, and a stage that is not public, are not asked for" "NotAStage"
expect_lacks "… neither of them" "Internal"
expect_status 0 "without the scan the list is taken as it is" matrix --no-scan
cp "$F/stages.txt" "$S/stages.txt"

printf 'Broken | OnA(nonsense: 1)\n' >> "$S/stages.txt"
expect_status 2 "an expression that does not compile on its own is refused" matrix --no-scan
expect_contains "… and named" "the expression of Broken does not compile on its own"
cp "$F/stages.txt" "$S/stages.txt"
expect_status 2 "a list that does not exist is refused" "$M" --no-modules --stages "$S/none.txt" --domains "$F/domains.txt"
expect_status 2 "an unknown argument is refused" "$M" --nonsense

# The package's own matrix, when there is a build to ask.
products="$("$ROOT/Scripts/xc.sh" products 2>/dev/null)"
if [ -d "$products/ZTronDSP.swiftmodule" ]; then
    expect_status 0 "the package's committed matrix is current" "$M" --check
else
    echo "  SKIP  the package's own matrix: there is no build (Scripts/xc.sh build)"
fi
finish
