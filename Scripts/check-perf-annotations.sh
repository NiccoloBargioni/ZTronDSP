#!/bin/bash
# WP-015. The build setting ZTRONDSP_PERF_ANNOTATIONS puts `@_noAllocation @_noLocks` on the
# package's pure-Swift leaf loops (RT-7, layer 2). The attributes are underscored and may
# change between toolchains, so they sit behind the setting and are a secondary check only.
#
#   Scripts/check-perf-annotations.sh            fixtures, then the package with the setting on
#   Scripts/check-perf-annotations.sh --fixtures fixtures only (fast; no package build)
#
# Fixtures (Tests/Fixtures/PerfAnnotations):
#   AllocatingLeaf.swift  must fail to build with the setting on, and build with it off
#   CleanLeaf.swift       must build either way
#
# The package build uses its own derived-data folder, so it does not disturb the usual one.

set -u -o pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$ROOT/Tests/Fixtures/PerfAnnotations"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
TARGET="arm64-apple-ios15.0-simulator"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
failures=0

compile() { # file, extra flags… → exit status of the compiler; diagnostics in $WORK/log
    local file="$1"; shift
    xcrun swiftc -frontend -c -primary-file "$file" -sdk "$SDK" -target "$TARGET" -swift-version 6 \
        -module-name PerfFixture -O -o "$WORK/out.o" "$@" >"$WORK/log" 2>&1
}

expect() { # description, expected (pass|fail), file, flags…
    local description="$1" expected="$2"; shift 2
    if compile "$@"; then actual=pass; else actual=fail; fi
    if [ "$actual" = "$expected" ]; then
        echo "ok    $description"
    else
        echo "FAIL  $description: expected the build to $expected, it did $actual"
        sed 's/^/        /' "$WORK/log" | head -12
        failures=$((failures + 1))
    fi
}

expect "an annotated leaf that allocates does not build with the setting on" fail "$FIXTURES/AllocatingLeaf.swift" -D ZTRONDSP_PERF_ANNOTATIONS
if ! grep -q -E "memory allocation|allocat" "$WORK/log"; then
    echo "FAIL  the failure does not name an allocation:"; sed 's/^/        /' "$WORK/log" | head -8
    failures=$((failures + 1))
fi
expect "the same leaf builds with the setting off (the attributes are absent)" pass "$FIXTURES/AllocatingLeaf.swift"
expect "a clean annotated leaf builds with the setting on" pass "$FIXTURES/CleanLeaf.swift" -D ZTRONDSP_PERF_ANNOTATIONS
expect "a clean annotated leaf builds with the setting off" pass "$FIXTURES/CleanLeaf.swift"

if [ "${1:-}" != "--fixtures" ] && [ "$failures" -eq 0 ]; then
    echo "building the package with ZTRONDSP_PERF_ANNOTATIONS on…"
    if ZTD_DERIVED="$ROOT/.build/xcode-perf" ZTD_CONFIG=Release ZTD_DEFINES="ZTRONDSP_PERF_ANNOTATIONS" \
        "$ROOT/Scripts/xc.sh" build >"$WORK/package.log" 2>&1; then
        echo "ok    the package builds with the setting on: its annotated leaf loops are clean"
    else
        echo "FAIL  the package does not build with the setting on:"
        grep -E "error" "$WORK/package.log" | head -20 | sed 's/^/        /'
        failures=$((failures + 1))
    fi
fi

[ "$failures" -eq 0 ] && echo "perf annotations: all checks passed" || { echo "perf annotations: $failures check(s) failed"; exit 1; }
