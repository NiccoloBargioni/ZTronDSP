#!/bin/bash
# WP-201, WP-222. Everything in CZTronDSP that may run on the audio I/O thread or in the
# analysis thread's steady state is declared ZTD_NONBLOCKING, and the manifest compiles the
# target with clang's function-effect warnings as errors (RT-1, RT-7 layer 1, E-03, E-32). This
# script proves that the mechanism bites and that the target passes it.
#
#   Scripts/check-function-effects.sh            fixtures, the target's sources, then the package build
#   Scripts/check-function-effects.sh --fixtures fixtures and sources only (fast; no package build)
#
# Fixtures (Tests/Fixtures/FunctionEffects), compiled with the flags the manifest gives the target:
#   AllocatingNonblocking.c    must fail to build: a non-blocking function calls malloc.
#                              It builds without the flags, so it is the flags that reject it.
#   UnlistedVDSPNonblocking.c  must fail to build: a vDSP call the allow-list does not name
#   WaitingWriteNonblocking.c  must fail to build: the ring's waiting write reached from
#                              non-blocking code (WP-222)
#   CleanNonblocking.c         must build: an allow-listed vDSP call, a builtin, the ring's write
#
# The flags are read from Package.swift. If the manifest stops enabling the warning, or stops
# treating it as an error, the script fails instead of passing on flags of its own.
#
# The package build uses its own derived-data folder, so it does not disturb the usual one, and
# starts from an empty one, so that every source of the target is compiled and seen. It runs on
# the simulator named by ZTD_DEVICE, as Scripts/xc.sh does.

set -u -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Tests/Fixtures/FunctionEffects"
SOURCES="$ROOT/Sources/CZTronDSP"
MANIFEST="$ROOT/Package.swift"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios15.0-simulator"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

fail() { echo "FAIL  $1"; failures=$((failures + 1)); }

# --- The flags, from the manifest -------------------------------------------------------------

# The declaration of the CZTronDSP target: from its name to the next target.
target_block="$(awk '/name: "CZTronDSP",/ { inside = 1 } inside && /^        \.(target|testTarget)\(/ && seen { exit } inside { seen = 1; print }' "$MANIFEST")"
flags=()
if echo "$target_block" | grep -q -E '\.enableWarning\("function-effects"\)'; then
    flags+=("-Wfunction-effects")
else
    fail "Package.swift does not enable the function-effects warning for CZTronDSP"
fi
if echo "$target_block" | grep -q -E '\.treatWarning\("function-effects", *as: *\.error\)'; then
    flags+=("-Werror=function-effects")
else
    fail "Package.swift does not treat the function-effects warning as an error for CZTronDSP"
fi
standard="$(grep -E 'cLanguageStandard: *\.' "$MANIFEST" | sed -E 's/.*cLanguageStandard: *\.([a-z0-9]+).*/\1/' | head -1)"
[ -n "$standard" ] && flags+=("-std=$standard")
echo "flags from the manifest: ${flags[*]-none}"

compile() { # file, extra flags… → exit status of the compiler; diagnostics in $WORK/log
    local file="$1"; shift
    xcrun --sdk iphonesimulator clang -x c -target "$TARGET" -isysroot "$SDK" \
        -I "$SOURCES/include" -I "$SOURCES" -fsyntax-only "$@" "$file" >"$WORK/log" 2>&1
}

expect() { # description, expected (pass|fail), file, flags…
    local description="$1" expected="$2"; shift 2
    local actual
    if compile "$@"; then actual=pass; else actual=fail; fi
    if [ "$actual" = "$expected" ]; then
        echo "ok    $description"
    else
        fail "$description: expected the build to $expected, it did $actual"
        sed 's/^/        /' "$WORK/log" | head -12
    fi
}

expect_diagnostic() { # pattern, what it should name
    if ! grep -q -E "$1" "$WORK/log"; then
        fail "the failure does not name $2:"
        sed 's/^/        /' "$WORK/log" | head -8
    fi
}

# --- Fixtures ---------------------------------------------------------------------------------

if [ "${#flags[@]}" -ge 2 ]; then
    expect "a non-blocking function that calls malloc does not build with the manifest's flags" fail \
        "$FIXTURES/AllocatingNonblocking.c" "${flags[@]}"
    expect_diagnostic "Wfunction-effects" "the function-effects check"
    expect_diagnostic "malloc" "malloc"
    expect "the same file builds without them (it is the flags that reject it)" pass \
        "$FIXTURES/AllocatingNonblocking.c" -std=c11 -Wno-function-effects
    expect "a vDSP call that is not on the allow-list does not build from non-blocking code" fail \
        "$FIXTURES/UnlistedVDSPNonblocking.c" "${flags[@]}"
    expect_diagnostic "Wfunction-effects" "the function-effects check"
    expect "the ring's waiting write cannot be reached from non-blocking code (WP-222)" fail \
        "$FIXTURES/WaitingWriteNonblocking.c" "${flags[@]}"
    expect_diagnostic "Wfunction-effects" "the function-effects check"
    expect_diagnostic "ztd_ring_write_waiting" "ztd_ring_write_waiting"
    expect "non-blocking code that keeps to the allow-list builds" pass \
        "$FIXTURES/CleanNonblocking.c" "${flags[@]}"
    [ -s "$WORK/log" ] && { fail "the clean fixture builds, but not silently:"; sed 's/^/        /' "$WORK/log" | head -8; }

    # --- The target's own sources -------------------------------------------------------------
    sources=0
    for file in "$SOURCES"/*.c; do
        sources=$((sources + 1))
        if ! compile "$file" "${flags[@]}" -Wall -Wshorten-64-to-32 || [ -s "$WORK/log" ]; then
            fail "$(basename "$file") does not build clean with the manifest's flags:"
            sed 's/^/        /' "$WORK/log" | head -12
        fi
    done
    [ "$failures" -eq 0 ] && echo "ok    the target's $sources sources build clean with the manifest's flags"
fi

# --- The package, as the manifest builds it -----------------------------------------------------

if [ "${1:-}" != "--fixtures" ] && [ "$failures" -eq 0 ]; then
    echo "building the package…"
    derived="$ROOT/.build/xcode-effects"
    rm -rf "$derived"   # a build that is up to date compiles nothing, and would show nothing
    if ZTD_DERIVED="$derived" "$ROOT/Scripts/xc.sh" build >"$WORK/package.log" 2>&1; then
        log="$derived/last-build-for-testing.log"
        compiled="$(grep -c -E "^CompileC .*/Sources/CZTronDSP/[A-Za-z_]+\.c " "$log")"
        checked="$(grep -E "/Sources/CZTronDSP/[A-Za-z_]+\.c " "$log" | grep -E "clang .* -c " | grep -c -F -- "-Werror\\=function-effects")"
        if [ "$compiled" -ge "$sources" ] && [ "$checked" -ge "$compiled" ]; then
            echo "ok    the package builds: all $sources sources of CZTronDSP compiled with -Werror=function-effects"
        else
            fail "the package builds, but $compiled of $sources CZTronDSP sources were compiled, $checked of them with -Werror=function-effects"
        fi
        if grep -E "/Sources/CZTronDSP/.*(warning|error):" "$log" | grep -v -E "^ +(cd|/)" | head -5 | grep -q .; then
            fail "the target does not build clean:"
            grep -E "/Sources/CZTronDSP/.*(warning|error):" "$log" | awk '!seen[$0]++' | head -8 | sed 's/^/        /'
        else
            echo "ok    the target builds clean: no diagnostic names a file of CZTronDSP"
        fi
    else
        fail "the package does not build:"
        grep -E "error" "$WORK/package.log" | head -20 | sed 's/^/        /'
    fi
fi

[ "$failures" -eq 0 ] && echo "function effects: all checks passed" || { echo "function effects: $failures check(s) failed"; exit 1; }
