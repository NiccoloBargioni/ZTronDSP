#!/bin/bash
# The documentation (WP-901b, VIS-2): every public symbol documented with its threading contract,
# and a documentation build without warnings.
#
#   Scripts/docs.sh               --audit, then --build
#   Scripts/docs.sh --audit       the audit of Scripts/lib/doc_audit.py on the last build: every
#                                 public symbol of the eight Swift modules has a documentation
#                                 comment of its own; every public type, protocol, global function
#                                 and member added to another module's type states its threading
#                                 contract; every declaration of the public C headers has a
#                                 comment; the code of every documentation catalog is a region of a
#                                 compiled test. The vocabulary of a contract, and how a member
#                                 inherits its type's: Scripts/lib/doc_audit.py --help
#   Scripts/docs.sh --build       xcodebuild docbuild of the package's scheme, which covers the
#                                 eight Swift modules, on the simulator of Scripts/xc.sh, into
#                                 derived data of its own (.build/docs); fails on any warning that
#                                 DocC or the compiler prints for the package's sources, prints
#                                 each, and prints the pages built per module. Then merges the
#                                 eight archives into one, .build/docs/ZTronDSP.doccarchive, the
#                                 documentation to publish, and fails on a link written as a path
#                                 (the landing page's links to the modules) that names no page of it
#
# The audit is part of CI gate 4, beside the API digest, and reads the same build: run
# Scripts/xc.sh build first. The documentation build is not a gate (§10.3 has nine); it is a
# step of the release checklist (WP-906).
#
# Options of --audit, for fixtures (when one is given, only what is given is audited):
#   --graphs DIR      symbol graphs already extracted with -skip-inherited-docs; no build is read
#   --sources DIR     Swift sources to scan (repeatable; default Sources)
#   --headers DIR     C headers (repeatable; default the public headers of both C targets)
#   --catalogs DIR    where the .docc catalogs are (repeatable; default Sources)
#   --report FILE     also write the findings, one per line, to FILE
#
# ZTD_DERIVED and ZTD_CONFIG are honoured as Scripts/xc.sh honours them (ZTD_CONFIG for --build
# too; --build always builds into .build/docs); so is ZTD_DEVICE, the simulator.
# ZTD_DOCS_XC, ZTD_DOCS_XCODEBUILD, ZTD_DOCS_DOCC and ZTD_DOCS_DERIVED stand in for
# Scripts/xc.sh, xcodebuild, `xcrun docc` and .build/docs (the self-test).
# Exit status: 0 nothing found, 1 a finding (or a warning, or a failed documentation build),
# 2 usage error or no build.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$ROOT/Scripts/lib/doc_audit.py"
# The eight Swift modules (§4.2): the facade's graph is empty, since it only re-exports.
MODULES="ZTronDSPCore ZTronDSPDesign ZTronDSPMetal ZTronDSPAnalysis ZTronDSPIO ZTronDSPUI ZTronDSP ZTronDSPTesting"
SCHEME="ZTronDSP-Package"
XC="${ZTD_DOCS_XC:-$ROOT/Scripts/xc.sh}"
XCODEBUILD="${ZTD_DOCS_XCODEBUILD:-xcodebuild}"
DOCC="${ZTD_DOCS_DOCC:-xcrun docc}"
DOCS_DERIVED="${ZTD_DOCS_DERIVED:-$ROOT/.build/docs}"
CONFIG="${ZTD_CONFIG:-Debug}"

audit=0; build=0; graphs=""; given=0; report=""
sources=(); headers=(); catalogs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --audit) audit=1 ;;
        --build) build=1 ;;
        --graphs|--sources|--headers|--catalogs|--report)
            [ $# -ge 2 ] || { echo "docs: $1 takes a value" >&2; exit 2; }
            case "$1" in
                --graphs) graphs="$2"; given=1 ;;
                --sources) sources+=("$2"); given=1 ;;
                --headers) headers+=("$2"); given=1 ;;
                --catalogs) catalogs+=("$2"); given=1 ;;
                --report) report="$2" ;;
            esac
            shift ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "docs: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
if [ "$audit" -eq 0 ] && [ "$build" -eq 0 ]; then audit=1; build=1; fi
if [ "$given" -eq 1 ] && [ "$audit" -eq 0 ]; then echo "docs: --graphs, --sources, --headers and --catalogs belong to --audit" >&2; exit 2; fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ztd-docs.XXXXXX")" || { echo "docs: cannot make a scratch folder" >&2; exit 2; }
trap 'case "$scratch" in */ztd-docs.??????) rm -rf "$scratch" ;; esac' EXIT

# ---------------------------------------------------------------------------------------------
# --audit
# ---------------------------------------------------------------------------------------------
run_audit() {
    local arguments=(audit --root "$ROOT")
    if [ "$given" -eq 0 ]; then
        local products maps sdk platform search=() output
        products="$("$XC" products)"
        if [ ! -d "$products/ZTronDSPCore.swiftmodule" ]; then
            echo "docs: no build at $products; run Scripts/xc.sh build" >&2
            return 2
        fi
        # The graphs as Scripts/api-digest.sh extracts them, with the comments a symbol only
        # inherits left out: what is counted is what the package wrote.
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
                    -omit-extension-block-symbols -skip-synthesized-members -skip-inherited-docs -output-dir "$graphs" 2>&1)"; then
                echo "docs: the symbol graph of $module could not be extracted:" >&2
                printf '%s\n' "$output" | head -10 | sed 's/^/    /' >&2
                return 2
            fi
        done
        sources=("$ROOT/Sources")
        headers=("$ROOT/Sources/CZTronDSP/include" "$ROOT/Sources/CZTronDSPTesting/include")
        catalogs=("$ROOT/Sources")
    fi
    [ -n "$graphs" ] && arguments+=(--graphs "$graphs")
    local folder
    for folder in ${sources[@]+"${sources[@]}"}; do arguments+=(--sources "$folder"); done
    for folder in ${headers[@]+"${headers[@]}"}; do arguments+=(--headers "$folder"); done
    for folder in ${catalogs[@]+"${catalogs[@]}"}; do arguments+=(--catalogs "$folder"); done
    [ -n "$report" ] && arguments+=(--report "$report")
    python3 "$ENGINE" "${arguments[@]}"
}

# ---------------------------------------------------------------------------------------------
# --build
# ---------------------------------------------------------------------------------------------
run_build() {
    local udid status archives log combined output inputs=() archive
    udid="$("$XC" device)" || { echo "docs: no simulator to build the documentation for" >&2; return 2; }
    archives="$DOCS_DERIVED/Build/Products/$CONFIG-iphonesimulator"
    log="$DOCS_DERIVED/docbuild.log"
    mkdir -p "$DOCS_DERIVED"
    # An archive of an earlier build would be counted as built now.
    [ -d "$archives" ] && find "$archives" -maxdepth 1 -name '*.doccarchive' -exec rm -rf {} +
    echo "docs: xcodebuild docbuild of $SCHEME ($CONFIG) into ${DOCS_DERIVED#"$ROOT"/}; the log is ${log#"$ROOT"/}"
    ( cd "$ROOT" && "$XCODEBUILD" docbuild -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$udid" \
        -derivedDataPath "$DOCS_DERIVED" -configuration "$CONFIG" ) > "$log" 2>&1
    status=$?
    python3 "$ENGINE" docbuild --log "$log" --archives "$archives" --root "$ROOT" --status "$status" || return $?
    # Each archive holds one module's pages; the landing page reaches the others by links written
    # as paths, which resolve in the archive the eight are merged into.
    combined="$DOCS_DERIVED/ZTronDSP.doccarchive"
    rm -rf "$combined"
    for archive in "$archives"/*.doccarchive; do inputs+=("$archive"); done
    if ! output="$($DOCC merge "${inputs[@]}" --synthesized-landing-page-name ZTronDSP \
            --synthesized-landing-page-kind Package --output-path "$combined" 2>&1)"; then
        echo "docs: the archives could not be merged into one:"
        printf '%s\n' "$output" | head -10 | sed 's/^/    /'
        return 1
    fi
    python3 "$ENGINE" links --archive "$combined" --root "$ROOT"
}

result=0
if [ "$audit" -eq 1 ]; then
    run_audit
    status=$?
    [ "$status" -eq 2 ] && exit 2
    [ "$status" -ne 0 ] && result=1
fi
if [ "$build" -eq 1 ]; then
    run_build
    status=$?
    [ "$status" -eq 2 ] && exit 2
    [ "$status" -ne 0 ] && result=1
fi
exit $result
