#!/bin/bash
# Self-test of the Metal Toolchain check of Scripts/xc.sh (DEP-4, brief 76).
#
# The build compiles the Metal shaders, so `xc.sh build` and `xc.sh test` stop before xcodebuild
# when Xcode's Metal Toolchain component is not installed: with one line that names
# `xcodebuild -downloadComponent MetalToolchain`, and the status of a run xc.sh refuses (64).
# Stand-ins for `xcrun`, `metal` and `xcodebuild` on the PATH play the three machines: one whose
# `xcrun -f metal` finds nothing, one where it finds only the stand-in Xcode ships without the
# component (which says what is missing and fails), and one with the component installed. The
# stand-in `xcodebuild` records each call and builds nothing; derived data lands in the scratch
# folder. No simulator is touched.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
XC="$ROOT/Scripts/xc.sh"
make_scratch xc-test

echo "xc"

BIN="$SCRATCH/bin"
CALLS="$SCRATCH/xcodebuild.calls"
mkdir -p "$BIN"

# `xcrun -f metal` as each machine answers it, and the two `simctl list` calls of xc.sh's device
# lookup: the simulator exists and is booted, so nothing is created or booted.
cat > "$BIN/xcrun" <<'EOS'
#!/bin/bash
case "$*" in
    "-f metal")
        if [ "$ZTD_TEST_METAL" = "absent" ]; then
            echo "xcrun: error: unable to find utility \"metal\", not a developer tool or in PATH" >&2
            exit 72
        fi
        echo "$(dirname "$0")/metal" ;;
    "simctl list devices available"|"simctl list devices")
        echo "== Devices =="
        echo "-- iOS 27.0 --"
        echo "    ztdsp-xc-test (00000000-0000-0000-0000-00000000C0DE) (Booted)" ;;
    *)
        echo "xcrun stand-in: unexpected call: $*" >&2
        exit 1 ;;
esac
EOS
# The compiler when the component is installed; otherwise the stand-in of Xcode's own toolchain,
# with its words.
cat > "$BIN/metal" <<'EOS'
#!/bin/bash
if [ "$ZTD_TEST_METAL" = "installed" ]; then
    echo "Apple metal version 32023.921 (stand-in)"
    exit 0
fi
echo "error: error: cannot execute tool 'metal' due to missing Metal Toolchain; use: xcodebuild -downloadComponent MetalToolchain" >&2
exit 1
EOS
cat > "$BIN/xcodebuild" <<'EOS'
#!/bin/bash
printf '%s\n' "$*" >> "$ZTD_TEST_CALLS"
echo "** BUILD SUCCEEDED ** (stand-in)"
exit 0
EOS
chmod +x "$BIN/xcrun" "$BIN/metal" "$BIN/xcodebuild"

xc() {   # <absent|stub|installed> <arguments of xc.sh …>: xc.sh among the stand-ins
    local machine="$1"; shift
    : > "$CALLS"
    env -u ZTD_XCARGS -u ZTD_DEFINES -u ZTD_VERBOSE -u ZTD_RUNTIME -u ZTD_CONFIG \
        PATH="$BIN:/usr/bin:/bin" ZTD_TEST_METAL="$machine" ZTD_TEST_CALLS="$CALLS" \
        ZTD_DEVICE=ztdsp-xc-test ZTD_DERIVED="$SCRATCH/derived" "$XC" "$@"
}

one_line() {          # <name>: what xc.sh printed is one line
    if [ -n "$LAST_OUTPUT" ] && [ "$(printf '%s\n' "$LAST_OUTPUT" | wc -l | tr -d ' ')" = "1" ]; then
        pass "$1"
    else
        fail "$1" "$LAST_OUTPUT"
    fi
}
xcodebuild_not_called() {   # <name>
    if [ -s "$CALLS" ]; then fail "$1" "xcodebuild was called: $(cat "$CALLS")"; else pass "$1"; fi
}
xcodebuild_calls() {  # <name> <expected calls, one action per line, in order>
    local actions
    actions="$(sed -E 's/.* ([a-z-]+)( -only-testing:.*)?$/\1/' "$CALLS")"
    if [ "$actions" = "$2" ]; then pass "$1"; else fail "$1" "xcodebuild calls:
$(cat "$CALLS")"; fi
}

INSTALL="xcodebuild -downloadComponent MetalToolchain"

# Without the component, `build` refuses before it reaches xcodebuild.
expect_status 64 "build refuses when xcrun finds no Metal compiler" xc absent build
expect_contains "… with a line that names the command that installs the component" "$INSTALL"
one_line "… and nothing else"
xcodebuild_not_called "… before xcodebuild is called"

expect_status 64 "build refuses when the Metal compiler found is the stand-in Xcode ships without the component" xc stub build
expect_contains "… with the same line" "$INSTALL"
one_line "… and nothing else"
xcodebuild_not_called "… before xcodebuild is called"

expect_status 64 "test refuses without the component" xc absent test ZTronDSPMetalTests
one_line "… with one line"
expect_contains "… that names the command" "$INSTALL"
xcodebuild_not_called "… before it builds"
expect_status 64 "… also when only the stand-in is found" xc stub test

# The status is the one xc.sh gives every run it refuses.
expect_status 64 "an unknown command is refused with the same status" xc installed rebuild

# With the component installed, the check lets the build through.
expect_status 0 "build runs when the component is installed" xc installed build
expect_lacks "… and says nothing about the toolchain" "MetalToolchain"
xcodebuild_calls "… and builds everything for testing" "build-for-testing"
expect_status 0 "test runs when the component is installed" xc installed test ZTronDSPMetalTests
xcodebuild_calls "… builds first, then runs the tests" "build-for-testing
test-without-building"
if grep -q -- "-only-testing:ZTronDSPMetalTests" "$CALLS" && grep -q -- "-derivedDataPath $SCRATCH/derived" "$CALLS"; then
    pass "… with its filter, into the derived data it is given"
else
    fail "… with its filter, into the derived data it is given" "$(cat "$CALLS")"
fi

# What builds nothing does not check.
expect_status 0 "test-only runs without the component: it builds nothing" xc absent test-only ZTronDSPMetalTests
xcodebuild_calls "… and only runs the tests" "test-without-building"
expect_status 0 "products answers without the component" xc absent products
expect_contains "… with the products of the derived data" "$SCRATCH/derived/Build/Products/Debug-iphonesimulator"
xcodebuild_not_called "… and calls no xcodebuild"
expect_status 0 "device answers without the component" xc stub device
expect_contains "… with the simulator's UDID" "00000000-0000-0000-0000-00000000C0DE"

finish
