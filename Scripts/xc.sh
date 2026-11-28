#!/bin/bash
# Build and test helper. The package is built and tested with xcodebuild against an iOS
# simulator; plain `swift build` is not a supported path (DEP-4).
#
#   Scripts/xc.sh build                  build everything, tests included (build-for-testing)
#   Scripts/xc.sh test [filter ...]      build, then run tests
#   Scripts/xc.sh test-only [filter ...] run tests without building
#   Scripts/xc.sh products               print the directory that holds the built modules
#   Scripts/xc.sh device                 print the simulator's UDID (creating and booting it)
#
# A filter is a test target, Target/Suite or Target/Suite/test, as -only-testing takes them.
#
# The build compiles the Metal shaders into the resource bundle of ZTronDSPMetal (DEP-4), which
# needs Xcode's Metal Toolchain component. `build` and `test` check for it before they start: when
# the Metal compiler is missing, or is only the stand-in Xcode puts in its place, they stop with
# one line that names `xcodebuild -downloadComponent MetalToolchain`, and status 64, as for a
# command xc.sh does not know.
#
# Environment:
#   ZTD_DEVICE    simulator name (default ztdsp-27); created if it does not exist
#   ZTD_RUNTIME   runtime identifier for a device that has to be created (default: newest iOS)
#   ZTD_DERIVED   derived-data path (default <package>/.build/xcode)
#   ZTD_CONFIG    Debug (default) or Release
#   ZTD_VERBOSE   1 prints xcodebuild's full output instead of the summary
#   ZTD_XCARGS    extra xcodebuild arguments, e.g. "-enableCodeCoverage YES" (coverage is off
#                 unless it is asked for here: its instrumentation distorts timings)
#   ZTD_DEFINES   extra Swift compilation conditions, space-separated,
#                 e.g. "ZTRONDSP_PERF_ANNOTATIONS ZTRONDSP_SIGNPOSTS"
#
# The full log of the last run is kept at $ZTD_DERIVED/last-<action>.log.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE_NAME="${ZTD_DEVICE:-ztdsp-27}"
DERIVED="${ZTD_DERIVED:-$ROOT/.build/xcode}"
CONFIG="${ZTD_CONFIG:-Debug}"
SCHEME="ZTronDSP-Package"

device_udid() {
    local udid
    udid="$(xcrun simctl list devices available | grep -E "^ +${DEVICE_NAME} \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    if [ -z "$udid" ]; then
        local runtime="${ZTD_RUNTIME:-}"
        if [ -z "$runtime" ]; then
            runtime="$(xcrun simctl list runtimes | grep -E '^iOS ' | grep -v unavailable | tail -1 | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9-]+).*/\1/')"
        fi
        local type
        # The newest plain iPhone by its number: the list is not in that order, and a runtime
        # refuses device types that are too old for it.
        type="$(xcrun simctl list devicetypes | grep -E '^iPhone [0-9]+ \(' | sort -t' ' -k2,2n | tail -1 | sed -E 's/.*\((com\.apple[^)]*)\).*/\1/')"
        udid="$(xcrun simctl create "$DEVICE_NAME" "$type" "$runtime")" || { echo "xc.sh: cannot create simulator $DEVICE_NAME" >&2; return 1; }
    fi
    if ! xcrun simctl list devices | grep -F "$udid" | grep -q Booted; then
        xcrun simctl boot "$udid" >/dev/null 2>&1 || true
    fi
    echo "$udid"
}

summarise() {
    if [ "${ZTD_VERBOSE:-0}" = "1" ]; then
        cat
    else
        grep -E "error:|warning:|✘|recorded an issue|Test run with|\*\* (BUILD|TEST)|Testing failed|Fatal error|Crash|crashed|Restarting after unexpected exit|Assertion failed" \
            | grep -v -E "IDERunDestination|DVTDeviceOperation|appintentsmetadataprocessor" \
            | awk '!seen[$0]++'
    fi
}

run_xcodebuild() {
    local action="$1"; shift
    local udid
    udid="$(device_udid)" || return 1
    mkdir -p "$DERIVED"
    local log="$DERIVED/last-$action.log"
    local settings=()
    [ "$CONFIG" = "Release" ] && settings+=("ENABLE_TESTABILITY=YES")
    [ -n "${ZTD_DEFINES:-}" ] && settings+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=\$(inherited) ${ZTD_DEFINES}")
    # The scheme xcodebuild makes for a package gathers coverage unless told not to, and the
    # instrumentation slows plain loops severalfold: timings would not be the product's. Coverage
    # is on only when it is asked for (ZTD_XCARGS="-enableCodeCoverage YES", as the CI's gate does).
    local coverage=()
    case " ${ZTD_XCARGS:-} " in
        *" -enableCodeCoverage "*) ;;
        *) coverage=(-enableCodeCoverage NO) ;;
    esac
    # shellcheck disable=SC2086
    ( cd "$ROOT" && xcodebuild -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$DERIVED" \
        -configuration "$CONFIG" \
        -collect-test-diagnostics never \
        ${settings[@]+"${settings[@]}"} \
        ${coverage[@]+"${coverage[@]}"} \
        ${ZTD_XCARGS:-} "$action" "$@" 2>&1 ) | tee "$log" | summarise
    return "${PIPESTATUS[0]}"
}

# Whether the Metal compiler is installed: `xcrun -f metal` finds it, and it runs. Without the
# component Xcode still ships a `metal` that `xcrun -f` can find, which only says what is missing
# and fails, so finding one is not enough.
metal_toolchain_installed() {
    local compiler
    compiler="$(xcrun -f metal 2>/dev/null)" || return 1
    [ -n "$compiler" ] && [ -x "$compiler" ] && "$compiler" --version >/dev/null 2>&1
}

require_metal_toolchain() {
    metal_toolchain_installed && return 0
    echo "xc.sh: building compiles the Metal shaders, and Xcode's Metal Toolchain component is not installed: run \`xcodebuild -downloadComponent MetalToolchain\`, then build again" >&2
    exit 64
}

only_testing_args() {
    local args=()
    for filter in "$@"; do args+=("-only-testing:$filter"); done
    [ "${#args[@]}" -gt 0 ] && printf '%s\n' "${args[@]}"
}

command="${1:-}"; [ $# -gt 0 ] && shift

case "$command" in
    build)
        require_metal_toolchain
        run_xcodebuild build-for-testing
        ;;
    test)
        require_metal_toolchain
        run_xcodebuild build-for-testing || exit $?
        filters=(); while IFS= read -r line; do [ -n "$line" ] && filters+=("$line"); done < <(only_testing_args "$@")
        run_xcodebuild test-without-building ${filters[@]+"${filters[@]}"}
        ;;
    test-only)
        filters=(); while IFS= read -r line; do [ -n "$line" ] && filters+=("$line"); done < <(only_testing_args "$@")
        run_xcodebuild test-without-building ${filters[@]+"${filters[@]}"}
        ;;
    products)
        echo "$DERIVED/Build/Products/$CONFIG-iphonesimulator"
        ;;
    device)
        device_udid
        ;;
    *)
        sed -n '2,28p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
        exit 64
        ;;
esac
