#!/bin/bash
# The API digest (WP-013, VIS-3; CI gate 4 of §10.3).
#
#   Scripts/api-digest.sh --check  [--build]    compare the public API of the last build with Docs/API
#                                               and run the checks below
#   Scripts/api-digest.sh --update [--build]    rewrite Docs/API from the last build
#   Scripts/api-digest.sh --spec-map            check 3 alone, on the committed digests (no build)
#
# The digest is the public symbol graph of each target as sorted text, Docs/API/<Target>.txt:
# one line per public symbol with its declaration, its default values and its availability, one
# line per conformance, and for the facade one line per re-exported module. Members a type only
# inherits from a protocol extension (`!=` of every Equatable type) are left out: the
# conformance line stands for them. A difference between
# the build and the committed digest fails the check; changing the public API is a change request.
#
# The checks:
#   1. Every public initialiser of a type that conforms to PipelineStage or SequenceStage ends
#      in `isActive:` (API-5, ACT-1). Exempt types are listed in Scripts/lint/stage-init-exemptions.txt.
#   2. ZTronDSPDesign, ZTronDSPMetal, ZTronDSPAnalysis, ZTronDSPIO and ZTronDSPUI reference only
#      public symbols of the targets below them (EXT-1, VIS-1): each is type-checked a second
#      time as if it belonged to another package, so that a `package` symbol is out of reach.
#   3. The public API is the one the specification lists (WP-901a): Docs/API/spec-map.tsv has a
#      line for every top-level public symbol of every digest, every member a module adds to a
#      type of another module and every module the facade re-exports; every line names a symbol
#      the digests hold and a place that exists (a section or rule of the specification, a row of
#      Appendix A, a change request in Docs/Process/changes). Scripts/lib/spec_map.py says how a
#      line is written. With --check it reads the digests of the build; with --spec-map, the
#      committed ones.
#
# Options: --digests DIR   the committed digests (default Docs/API)
#          --graphs DIR    symbol graphs that are already extracted; no build is read, and
#                          check 2 is not run
#          --map FILE      the map of check 3 (default: spec-map.tsv beside the digests). When
#                          --digests names another folder and it holds no map, check 3 is not
#                          run, and that is said
#          --spec FILE     the specification check 3 reads (default Docs/Specification/ZTronDSP-SPEC.md)
#          --changes DIR   the change requests check 3 reads (default Docs/Process/changes)
#          --skip-public-only
#
# For fixtures and for one target at a time:
#   Scripts/api-digest.sh --public-only MODULE --sources DIR --import DIR [--host] [--package-name NAME]
#
# ZTD_DERIVED and ZTD_CONFIG are honoured as Scripts/xc.sh honours them.
# Exit status: 0 ok, 1 a difference or a failed check, 2 usage error, no build, or a check that
# could not run.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/Scripts/lib/api_digest.py"

# §4.2, top to bottom, and the two C halves.
MODULES="CZTronDSP ZTronDSPCore ZTronDSPDesign ZTronDSPMetal ZTronDSPAnalysis ZTronDSPIO ZTronDSPUI ZTronDSP ZTronDSPTesting CZTronDSPTesting"
PUBLIC_ONLY_TARGETS="ZTronDSPDesign ZTronDSPMetal ZTronDSPAnalysis ZTronDSPIO ZTronDSPUI"
PACKAGE_NAME="ztrondsp"            # what Xcode passes as -package-name for this package
FOREIGN_PACKAGE_NAME="ztrondsp_seen_from_another_package"

mode=""; build=0; digests="$ROOT/Docs/API"; digests_given=0; graphs=""; skip_public_only=0
public_module=""; public_sources=""; public_import=""; host=0
map_option=""; spec="$ROOT/Docs/Specification/ZTronDSP-SPEC.md"; changes="$ROOT/Docs/Process/changes"
while [ $# -gt 0 ]; do
    case "$1" in
        --check|--update|--spec-map) mode="${1#--}" ;;
        --build) build=1 ;;
        --skip-public-only) skip_public_only=1 ;;
        --host) host=1 ;;
        --digests|--graphs|--public-only|--sources|--import|--package-name|--map|--spec|--changes)
            [ $# -ge 2 ] || { echo "api-digest: $1 takes a value" >&2; exit 2; }
            case "$1" in
                --digests) digests="$2"; digests_given=1 ;;
                --graphs) graphs="$2" ;;
                --public-only) mode="public-only"; public_module="$2" ;;
                --sources) public_sources="$2" ;;
                --import) public_import="$2" ;;
                --package-name) PACKAGE_NAME="$2" ;;
                --map) map_option="$2" ;;
                --spec) spec="$2" ;;
                --changes) changes="$2" ;;
            esac
            shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "api-digest: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$mode" ] || { echo "api-digest: say --check, --update or --spec-map (see --help)" >&2; exit 2; }

# ---------------------------------------------------------------------------------------------
# Check 3 over a folder of digests: does the map list every public symbol, truly?
#   spec_map <digests dir>      Status: 0 the map holds, 1 a finding, 2 the check could not run.
# ---------------------------------------------------------------------------------------------
spec_map() {
    local map_file="$map_option"
    if [ -z "$map_file" ]; then
        map_file="$digests/spec-map.tsv"
        if [ "$digests_given" -eq 1 ] && [ ! -f "$map_file" ]; then
            echo "api-digest: ${digests#"$ROOT"/} holds no spec-map.tsv, so check 3 (the map of the public API) is not run"
            return 0
        fi
    fi
    python3 "$ROOT/Scripts/lib/spec_map.py" check --digests "$1" --map "$map_file" --spec "$spec" --changes "$changes" \
        --label "${map_file#"$ROOT"/}"
}

if [ "$mode" = "spec-map" ]; then
    spec_map "$digests"
    exit $?
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ztd-api-digest.XXXXXX")" || { echo "api-digest: cannot make a scratch folder" >&2; exit 2; }
trap 'case "$scratch" in */ztd-api-digest.??????) rm -rf "$scratch" ;; esac' EXIT

# ---------------------------------------------------------------------------------------------
# Does a target reach only public symbols of the modules it imports?
#   public_only <module> <sources dir> <flag> …
# The sources are type-checked twice: under the package's own name, which must succeed (the
# control), and under a foreign name. What fails only the second time is a use of a `package`
# symbol of another target. Status: 0 public only, 1 a non-public reference, 2 the control failed.
# ---------------------------------------------------------------------------------------------
public_only() {
    local module="$1" sources="$2"; shift 2
    local files=()
    while IFS= read -r file; do [ -n "$file" ] && files+=("$file"); done <<EOF_SOURCES
$(find "$sources" -type f -name '*.swift' | LC_ALL=C sort)
EOF_SOURCES
    if [ "${#files[@]}" -eq 0 ]; then
        echo "api-digest: $module has no Swift sources under $sources" >&2
        return 2
    fi
    if grep -q -E 'Bundle\.module|\.module\b' "${files[@]}" 2>/dev/null; then
        # SwiftPM generates this accessor for a target with resources; it is not among the sources.
        mkdir -p "$scratch/stubs"
        printf 'import Foundation\nextension Foundation.Bundle { static let module = Bundle.main }\n' > "$scratch/stubs/$module-resource-bundle.swift"
        files+=("$scratch/stubs/$module-resource-bundle.swift")
    fi
    local control foreign
    control="$(xcrun swiftc -typecheck -parse-as-library -module-name "$module" -package-name "$PACKAGE_NAME" "$@" "${files[@]}" 2>&1)"
    if [ $? -ne 0 ]; then
        echo "api-digest: $module does not type-check under its own package name, so its references could not be checked:" >&2
        printf '%s\n' "$control" | grep -E "error:" | head -15 | sed 's/^/    /' >&2
        return 2
    fi
    foreign="$(xcrun swiftc -typecheck -parse-as-library -module-name "$module" -package-name "$FOREIGN_PACKAGE_NAME" "$@" "${files[@]}" 2>&1)"
    if [ $? -ne 0 ]; then
        echo "api-digest: $module references symbols that are not public (EXT-1, VIS-1):"
        printf '%s\n' "$foreign" | grep -E "error:" | sed -E "s|^$ROOT/||" | sort -u | head -40 | sed 's/^/    /'
        return 1
    fi
    echo "api-digest: $module references public symbols only"
    return 0
}

if [ "$mode" = "public-only" ]; then
    [ -n "$public_sources" ] && [ -d "$public_sources" ] || { echo "api-digest: --public-only needs --sources DIR" >&2; exit 2; }
    flags=(-swift-version 6 -diagnostic-style llvm)
    if [ "$host" -eq 1 ]; then
        flags+=(-target "$(uname -m)-apple-macosx14.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)")
    else
        flags+=(-target "$(uname -m)-apple-ios15.0-simulator" -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)")
    fi
    [ -n "$public_import" ] && flags+=(-I "$public_import")
    public_only "$public_module" "$public_sources" "${flags[@]}"
    exit $?
fi

# ---------------------------------------------------------------------------------------------
# --check and --update
# ---------------------------------------------------------------------------------------------
from_build=0
if [ -z "$graphs" ]; then
    from_build=1
    if [ "$build" -eq 1 ]; then
        "$ROOT/Scripts/xc.sh" build || { echo "api-digest: the build failed" >&2; exit 2; }
    fi
    products="$("$ROOT/Scripts/xc.sh" products)"
    if [ ! -d "$products/ZTronDSPCore.swiftmodule" ]; then
        echo "api-digest: no build at $products; run Scripts/api-digest.sh --$mode --build" >&2
        exit 2
    fi
    maps="$(cd "$products/../.." && pwd)/Intermediates.noindex/GeneratedModuleMaps-iphonesimulator"
    sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"
    platform="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"
    search=(-target "$(uname -m)-apple-ios15.0-simulator" -sdk "$sdk" -I "$products" -F "$products" -F "$products/PackageFrameworks"
            -F "$platform/Developer/Library/Frameworks" -I "$platform/Developer/usr/lib")
    for map in "$maps"/C*.modulemap; do
        [ -f "$map" ] && search+=(-Xcc "-fmodule-map-file=$map")
    done
    graphs="$scratch/graphs"
    mkdir -p "$graphs"
    for module in $MODULES; do
        if ! output="$(xcrun swift-symbolgraph-extract -module-name "$module" "${search[@]}" -minimum-access-level public \
                -omit-extension-block-symbols -skip-synthesized-members -output-dir "$graphs" 2>&1)"; then
            echo "api-digest: the symbol graph of $module could not be extracted:" >&2
            printf '%s\n' "$output" | head -10 | sed 's/^/    /' >&2
            exit 2
        fi
    done
elif [ ! -d "$graphs" ]; then
    echo "api-digest: there is no folder $graphs" >&2
    exit 2
fi

fresh="$scratch/digests"
render=(render --graphs "$graphs" --out "$fresh")
if [ "$from_build" -eq 1 ]; then
    for module in $MODULES; do render+=(--module "$module"); done
    render+=(--reexports "ZTronDSP=$ROOT/Sources/ZTronDSP")
fi
python3 "$ENGINE" "${render[@]}" || exit 2

if [ "$mode" = "update" ]; then
    mkdir -p "$digests"
    for old in "$digests"/*.txt; do
        [ -f "$old" ] && [ ! -f "$fresh/$(basename "$old")" ] && rm "$old"
    done
    cp "$fresh"/*.txt "$digests"/
    echo "api-digest: $(ls "$fresh" | wc -l | tr -d ' ') digests written to ${digests#"$ROOT"/}"
    exit 0
fi

status=0
python3 "$ENGINE" compare --fresh "$fresh" --committed "$digests" || status=1
python3 "$ENGINE" rules --graphs "$graphs" --exemptions "$ROOT/Scripts/lint/stage-init-exemptions.txt" || status=1
spec_map "$fresh"
result=$?
if [ "$result" -eq 2 ]; then exit 2; fi
[ "$result" -eq 0 ] || status=1

if [ "$from_build" -eq 1 ] && [ "$skip_public_only" -eq 0 ]; then
    for module in $PUBLIC_ONLY_TARGETS; do
        public_only "$module" "$ROOT/Sources/$module" -swift-version 6 -diagnostic-style llvm -DSWIFT_PACKAGE -DDEBUG "${search[@]}"
        result=$?
        if [ "$result" -eq 2 ]; then exit 2; fi
        [ "$result" -eq 0 ] || status=1
    done
fi
exit $status
