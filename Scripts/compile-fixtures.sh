#!/bin/bash
# The compile-fixture harness (WP-009; CI gate 3 of §10.3; the order rules of §5.8).
#
#   Scripts/compile-fixtures.sh                 type-check Tests/CompileFixtures against the last build
#   Scripts/compile-fixtures.sh --build         build first (Scripts/xc.sh build)
#   Scripts/compile-fixtures.sh --valid DIR --invalid DIR
#                                               other fixture folders (either may be given alone)
#   Scripts/compile-fixtures.sh --no-modules    do not put the package's modules on the search path
#   Scripts/compile-fixtures.sh --jobs N        fixtures type-checked at once (default: one per core)
#
# Every *.swift file under the valid folder must type-check. Every *.swift file under the
# invalid folder must fail to type-check, and the compiler's output must contain each sentence
# its header names:
#
#     // expect: MelScale needs a linear-frequency spectrum of magnitudes or powers
#
# A valid file that fails, an invalid file that compiles, an invalid file without an
# `// expect:` line, and an invalid file that fails with other words each fail the run. A file
# may add compiler flags with `// flags: -parse-as-library`.
#
# A fixture is one file, type-checked on its own as a client of the package would be: in the
# Swift 6 language mode, for the iOS 15 simulator, against the modules of an existing build
# (ZTD_DERIVED and ZTD_CONFIG are honoured as Scripts/xc.sh honours them), with no access to
# `package` or internal symbols.
#
# Exit status: 0 all fixtures behave, 1 a fixture misbehaves, 2 usage error or no build,
# 3 no fixture was found.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------------------------
# The worker: one fixture. Invoked by xargs as `--worker <results dir> <flags file> <record>`,
# where a record is `<index>|<kind>|<path>`.
# ---------------------------------------------------------------------------------------------
if [ "${1:-}" = "--worker" ]; then
    results="$2"; flags_file="$3"; record="$4"
    index="${record%%|*}"; rest="${record#*|}"; kind="${rest%%|*}"; file="${rest#*|}"

    flags=()
    while IFS= read -r flag; do flags+=("$flag"); done < "$flags_file"
    extra="$(sed -n -E 's|^// flags:[[:space:]]*(.*)$|\1|p' "$file" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    output="$(xcrun swiftc "${flags[@]}" $extra "$file" 2>&1)"
    status=$?

    verdict="ok"; reason=""
    if printf '%s' "$output" | grep -q -E "error: (no such module|cannot load module|missing required module|unable to load standard library)"; then
        verdict="FAIL"; reason="a module could not be loaded: this is the harness or the build, not the fixture"
    elif [ "$kind" = "valid" ]; then
        if [ "$status" -ne 0 ]; then verdict="FAIL"; reason="it is filed as valid and does not compile"; fi
    else
        expectations="$(sed -n -E 's|^// expect:[[:space:]]*(.*[^[:space:]])[[:space:]]*$|\1|p' "$file")"
        if [ -z "$expectations" ]; then
            verdict="FAIL"; reason="it is filed as invalid and names no sentence (\`// expect: …\`)"
        elif [ "$status" -eq 0 ]; then
            verdict="FAIL"; reason="it is filed as invalid and compiles"
        else
            while IFS= read -r sentence; do
                if ! printf '%s' "$output" | grep -q -F -- "$sentence"; then
                    verdict="FAIL"; reason="it fails, but not with the sentence: $sentence"
                    break
                fi
            done <<EOF_EXPECT
$expectations
EOF_EXPECT
        fi
    fi

    {
        printf '%s\n%s\n%s\n%s\n' "$verdict" "$kind" "$file" "$reason"
        [ "$verdict" = "FAIL" ] && printf '%s\n' "$output" | head -30
    } > "$results/$(printf '%06d' "$index").result"
    exit 0
fi

# ---------------------------------------------------------------------------------------------

valid=""; invalid=""; build=0; modules=1; jobs="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"; explicit=0
while [ $# -gt 0 ]; do
    case "$1" in
        --build) build=1 ;;
        --no-modules) modules=0 ;;
        --valid) [ $# -ge 2 ] || { echo "compile-fixtures: --valid takes a folder" >&2; exit 2; }; valid="$2"; explicit=1; shift ;;
        --invalid) [ $# -ge 2 ] || { echo "compile-fixtures: --invalid takes a folder" >&2; exit 2; }; invalid="$2"; explicit=1; shift ;;
        --jobs) [ $# -ge 2 ] || { echo "compile-fixtures: --jobs takes a number" >&2; exit 2; }; jobs="$2"; shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "compile-fixtures: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$explicit" -eq 0 ]; then
    valid="$ROOT/Tests/CompileFixtures/valid"
    invalid="$ROOT/Tests/CompileFixtures/invalid"
fi
for folder in "$valid" "$invalid"; do
    if [ -n "$folder" ] && [ ! -d "$folder" ]; then echo "compile-fixtures: there is no folder $folder" >&2; exit 2; fi
done
case "$jobs" in ''|*[!0-9]*|0) echo "compile-fixtures: --jobs takes a positive number" >&2; exit 2 ;; esac

if [ "$build" -eq 1 ]; then
    "$ROOT/Scripts/xc.sh" build || { echo "compile-fixtures: the build failed" >&2; exit 2; }
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ztd-compile-fixtures.XXXXXX")" || { echo "compile-fixtures: cannot make a scratch folder" >&2; exit 2; }
trap 'case "$scratch" in */ztd-compile-fixtures.??????) rm -rf "$scratch" ;; esac' EXIT
mkdir -p "$scratch/results"

sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)" || { echo "compile-fixtures: no iOS simulator SDK" >&2; exit 2; }
platform="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
{
    printf '%s\n' -typecheck -target "$(uname -m)-apple-ios15.0-simulator" -sdk "$sdk" -swift-version 6 -diagnostic-style llvm
    if [ "$modules" -eq 1 ]; then
        products="$("$ROOT/Scripts/xc.sh" products)"
        if [ ! -d "$products/ZTronDSPCore.swiftmodule" ]; then
            echo "compile-fixtures: no build at $products; run Scripts/compile-fixtures.sh --build" >&2
            exit 2
        fi
        maps="$(cd "$products/../.." && pwd)/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator"
        printf '%s\n' -I "$products" -F "$products" -F "$products/PackageFrameworks"
        # Swift Testing and XCTest, for a fixture that imports the test product, with the macros of
        # Swift Testing: `#_sourceLocation` is the default of a source location in ZTronDSPTesting.
        printf '%s\n' -F "$platform/Developer/Library/Frameworks" -I "$platform/Developer/usr/lib"
        toolchain="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
        if [ -d "$toolchain/lib/swift/host/plugins/testing" ]; then
            printf '%s\n' -plugin-path "$toolchain/lib/swift/host/plugins/testing"
        fi
        for map in "$maps"/C*.modulemap; do
            [ -f "$map" ] && printf '%s\n' -Xcc "-fmodule-map-file=$map"
        done
    fi
} > "$scratch/flags" || exit 2

count=0
: > "$scratch/records"
for kind in valid invalid; do
    folder="$valid"; [ "$kind" = "invalid" ] && folder="$invalid"
    [ -n "$folder" ] || continue
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        count=$((count + 1))
        printf '%s|%s|%s\0' "$count" "$kind" "$file" >> "$scratch/records"
    done <<EOF_FILES
$(find "$folder" -type f -name '*.swift' | LC_ALL=C sort)
EOF_FILES
done

if [ "$count" -eq 0 ]; then
    echo "compile-fixtures: no fixture was found under ${valid:-(no valid folder)} and ${invalid:-(no invalid folder)}"
    exit 3
fi

xargs -0 -n 1 -P "$jobs" "${BASH_SOURCE[0]}" --worker "$scratch/results" "$scratch/flags" < "$scratch/records"

failed=0; valid_count=0; invalid_count=0; done_count=0
for result in "$scratch/results"/*.result; do
    [ -f "$result" ] || continue
    done_count=$((done_count + 1))
    verdict="$(sed -n '1p' "$result")"; kind="$(sed -n '2p' "$result")"; file="$(sed -n '3p' "$result")"; reason="$(sed -n '4p' "$result")"
    if [ "$kind" = "valid" ]; then valid_count=$((valid_count + 1)); else invalid_count=$((invalid_count + 1)); fi
    if [ "$verdict" != "ok" ]; then
        failed=$((failed + 1))
        printf 'compile-fixtures: FAIL %s: %s\n' "${file#"$ROOT"/}" "$reason"
        sed -n '5,$p' "$result" | sed 's/^/    | /'
    fi
done
if [ "$done_count" -ne "$count" ]; then
    echo "compile-fixtures: $((count - done_count)) of $count fixtures produced no result"
    failed=$((failed + count - done_count))
fi

if [ "$failed" -ne 0 ]; then
    echo "compile-fixtures: $failed of $count fixtures misbehave ($valid_count valid, $invalid_count invalid)"
    exit 1
fi
echo "compile-fixtures: $valid_count valid fixtures compile, $invalid_count invalid fixtures fail with their sentences"
exit 0
