#!/bin/bash
# Builds the gallery project and runs its tests on a named simulator.
#
#   Examples/ZTronDSPGallery/gallery.sh app                   build the application alone
#   Examples/ZTronDSPGallery/gallery.sh build                 build the application and both test targets
#   Examples/ZTronDSPGallery/gallery.sh test [filter ...]     build, then run tests
#   Examples/ZTronDSPGallery/gallery.sh test-only [filter ...] run tests without building
#   Examples/ZTronDSPGallery/gallery.sh hosted                build, then the hosted suites (GalleryTests)
#   Examples/ZTronDSPGallery/gallery.sh ui                    build, then the UI tests (GalleryUITests)
#   Examples/ZTronDSPGallery/gallery.sh logs DIR              copy the spikes' logs out of the application's container
#   Examples/ZTronDSPGallery/gallery.sh device                print the simulator's UDID (creating and booting it)
#
# A filter is what -only-testing takes: GalleryTests, GalleryTests/InApp/StabilityTests,
# GalleryUITests/PinchSpikeUITests/testName.
#
# Environment:
#   ZTD_DEVICE    simulator name (default ztdsp-27); created if it does not exist
#   ZTD_RUNTIME   runtime identifier for a device that has to be created (default: newest iOS)
#   ZTD_TYPE      device type for a device that has to be created (default: the newest plain iPhone)
#   ZTD_DERIVED   derived-data path (default <package>/.build/gallery)
#   ZTD_CONFIG    Debug (default) or Release. `app` in Release is the application as it ships;
#                 `build` and `test` in Release switch testability on, which the hosted tests need.
#   ZTD_VERBOSE   1 prints xcodebuild's full output instead of the summary
#
# The full log of the last run is kept at $ZTD_DERIVED/last-<action>.log. Every build product
# stays under the package's .build directory.
#
# While tests run, the script answers the hosted tests that ask for the application to leave
# the foreground and to come back (the function `stagehand` below): it launches Settings on
# the simulator, and then the gallery again.

set -u -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DEVICE_NAME="${ZTD_DEVICE:-ztdsp-27}"
DERIVED="${ZTD_DERIVED:-$ROOT/.build/gallery}"
CONFIG="${ZTD_CONFIG:-Debug}"
PROJECT="$HERE/ZTronDSPGallery.xcodeproj"
SCHEME="ZTronDSPGallery"
BUNDLE="com.zombietron.ztrondsp.gallery"

device_udid() {
    local udid
    udid="$(xcrun simctl list devices available | grep -E "^ +${DEVICE_NAME} \(" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
    if [ -z "$udid" ]; then
        local runtime="${ZTD_RUNTIME:-}"
        if [ -z "$runtime" ]; then
            runtime="$(xcrun simctl list runtimes | grep -E '^iOS ' | grep -v unavailable | tail -1 | sed -E 's/.* - (com\.apple\.CoreSimulator\.SimRuntime\.[A-Za-z0-9-]+).*/\1/')"
        fi
        local type="${ZTD_TYPE:-}"
        if [ -z "$type" ]; then
            type="$(xcrun simctl list devicetypes | grep -E '^iPhone [0-9]+ \(' | sort -t' ' -k2,2n | tail -1 | sed -E 's/.*\((com\.apple[^)]*)\).*/\1/')"
        fi
        udid="$(xcrun simctl create "$DEVICE_NAME" "$type" "$runtime")" || { echo "gallery.sh: cannot create simulator $DEVICE_NAME" >&2; return 1; }
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
        grep -E "error:|warning:|✘|recorded an issue|recorded a known issue|Test run with|Executed [0-9]+ tests?|\*\* (BUILD|TEST)|Testing failed|Fatal error|Crash|crashed|Restarting after unexpected exit|Assertion failed|^ZTD" \
            | grep -v -E "IDERunDestination|DVTDeviceOperation|appintentsmetadataprocessor|is implemented in both" \
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
    # The hosted tests reach into the package with `@testable import`: a Release build for
    # testing needs testability switched on for it. The application alone is built as it is.
    local testing=()
    if [ "$action" != "build" ]; then
        # What xcodebuild takes only with an action that tests.
        testing+=(-enableCodeCoverage NO -collect-test-diagnostics never -parallel-testing-enabled NO)
        [ "$CONFIG" = "Release" ] && settings+=("ENABLE_TESTABILITY=YES")
    fi
    ( cd "$HERE" && xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$DERIVED" \
        -configuration "$CONFIG" \
        ${testing[@]+"${testing[@]}"} \
        ${settings[@]+"${settings[@]}"} \
        "$action" "$@" 2>&1 ) | tee "$log" | summarise
    return "${PIPESTATUS[0]}"
}

only_testing_args() {
    for filter in "$@"; do printf '%s\n' "-only-testing:$filter"; done
}

# What a hosted test cannot do from inside the application: bring another application to the
# front, and the gallery back. A test asks by writing `leave` or `return` into the file
# Documents/stagehand-request of the application's container (GalleryTests/Support/Stagehand.swift).
stagehand() {
    local udid="$1" container="" request what
    while :; do
        if [ -z "$container" ] || [ ! -d "$container" ]; then
            container="$(xcrun simctl get_app_container "$udid" "$BUNDLE" data 2>/dev/null)"
        fi
        request="$container/Documents/stagehand-request"
        if [ -n "$container" ] && [ -f "$request" ]; then
            what="$(cat "$request" 2>/dev/null)"
            rm -f "$request"
            case "$what" in
                leave) xcrun simctl launch "$udid" com.apple.Preferences >/dev/null 2>&1 ;;
                return) xcrun simctl launch "$udid" "$BUNDLE" >/dev/null 2>&1 ;;
            esac
        fi
        sleep 1
    done
}

run_tests() {
    local filters=() udid helper status
    while IFS= read -r line; do [ -n "$line" ] && filters+=("$line"); done < <(only_testing_args "$@")
    udid="$(device_udid)" || return 1
    stagehand "$udid" &
    helper=$!
    # xcodebuild hands a variable that begins with TEST_RUNNER_ to the tests without the prefix.
    TEST_RUNNER_GALLERY_STAGEHAND=1 run_xcodebuild test-without-building ${filters[@]+"${filters[@]}"}
    status=$?
    kill "$helper" 2>/dev/null
    wait "$helper" 2>/dev/null
    return $status
}

command="${1:-}"; [ $# -gt 0 ] && shift

case "$command" in
    app)
        run_xcodebuild build
        ;;
    build)
        run_xcodebuild build-for-testing
        ;;
    test)
        run_xcodebuild build-for-testing || exit $?
        run_tests "$@"
        ;;
    test-only)
        run_tests "$@"
        ;;
    hosted)
        run_xcodebuild build-for-testing || exit $?
        run_tests GalleryTests
        ;;
    ui)
        run_xcodebuild build-for-testing || exit $?
        run_tests GalleryUITests
        ;;
    logs)
        target="${1:?gallery.sh logs DIR}"
        udid="$(device_udid)" || exit 1
        container="$(xcrun simctl get_app_container "$udid" "$BUNDLE" data)" || { echo "gallery.sh: the gallery is not installed on $DEVICE_NAME" >&2; exit 1; }
        mkdir -p "$target"
        found=0
        for file in "$container"/Documents/*.log; do
            [ -e "$file" ] || continue
            cp "$file" "$target/" && found=$((found + 1))
        done
        echo "gallery.sh: $found log(s) copied to $target"
        ;;
    device)
        device_udid
        ;;
    *)
        sed -n '2,30p' "${BASH_SOURCE[0]}" | sed -E 's/^# ?//'
        exit 64
        ;;
esac
