#!/bin/bash
# Self-test of Scripts/docs.sh (WP-901b).
#
# The fixture module under Tests/Fixtures/Docs is compiled for the host and its symbol graph
# extracted as docs.sh extracts the package's, so the audit reads real graphs and needs neither a
# simulator nor a build of the package. Two variants each add one seeded file to it: a bare
# symbol, and a type without a threading contract. The documentation build is run among stand-ins
# for Scripts/xc.sh and xcodebuild.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/Docs"
DOCS="$ROOT/Scripts/docs.sh"
make_scratch docs-test
HOST="$(uname -m)-apple-macosx14.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

graphs_of() {   # <name of the variant> <source folder> … : modules/ and graphs/ of the variant in the scratch folder
    local variant="$1"; shift
    local files=() folder
    for folder in "$@"; do files+=("$folder"/*.swift); done
    mkdir -p "$SCRATCH/$variant/modules" "$SCRATCH/$variant/graphs"
    xcrun swiftc -emit-module -module-name DocFixture -parse-as-library -swift-version 6 -target "$HOST" -sdk "$SDK" \
        -emit-module-path "$SCRATCH/$variant/modules/DocFixture.swiftmodule" "${files[@]}" 2>&1 || return 1
    xcrun swift-symbolgraph-extract -module-name DocFixture -target "$HOST" -sdk "$SDK" -I "$SCRATCH/$variant/modules" \
        -minimum-access-level public -omit-extension-block-symbols -skip-synthesized-members -skip-inherited-docs \
        -output-dir "$SCRATCH/$variant/graphs" 2>&1 || return 1
}
audit() {       # <variant> <source folder> … : the audit of that variant's graphs and sources
    local variant="$1"; shift
    local arguments=(--audit --graphs "$SCRATCH/$variant/graphs") folder
    for folder in "$@"; do arguments+=(--sources "$folder"); done
    "$DOCS" "${arguments[@]}"
}

echo "docs"
for variant in "clean $F/Clean" "bare $F/Clean $F/BareSymbol" "contract $F/Clean $F/NoContract"; do
    # shellcheck disable=SC2086
    if ! output="$(graphs_of $variant)"; then fail "the fixture module (${variant%% *}) compiles and its graph is extracted" "$output"; finish; exit 1; fi
done
pass "the fixture modules compile and their symbol graphs are extracted"

# A clean pass.
expect_status 0 "a module whose every symbol is documented with its contract passes" audit clean "$F/Clean"
expect_contains "… counted" "docs: DocFixture: "
expect_contains "… and said" "every public symbol is documented with its threading contract (VIS-2)"
expect_contains "… a member of another module's type that implements a stated requirement inherits its contract (CR-033)" " 0 without a contract"
expect_lacks "… an unavailable overload whose comment names its diagnostic needs no contract" "levels(_ values: [String])"

# A seeded bare symbol.
expect_status 1 "a seeded public function without a comment fails" audit bare "$F/Clean" "$F/BareSymbol"
expect_contains "… in the symbol graph" "[no comment] function bare(): no documentation comment of its own (VIS-2)"
expect_contains "… and in the sources, with its file and line" "Tests/Fixtures/Docs/BareSymbol/Bare.swift:4: [source] \`public func bare() -> Int {\`"
expect_contains "a comment that a witness only inherits from its requirement does not count" "[no comment] method QuietMeter.read(): no documentation comment of its own"
expect_contains "… and the number of findings is said" "docs: 4 findings (VIS-2)"

# A seeded type without a threading contract.
expect_status 1 "a seeded type whose comment states no contract fails" audit contract "$F/Clean" "$F/NoContract"
expect_contains "… with what its comment lacks" "[no contract] structure ClampedLevel: its comment does not say the context that may call it or whether it allocates (VIS-2; structure)"
expect_contains "an unavailable overload whose comment does not say it exists for its diagnostic fails" "an unavailable declaration whose comment does not say that it exists for its diagnostic (ORD-4, CR-033)"
expect_lacks "… while its members, which the type's statement would cover, are not asked for a contract" "ClampedLevel.init"

# The C headers.
expect_status 0 "a header whose every declaration has a comment passes" "$DOCS" --audit --headers "$F/Headers/clean"
expect_contains "… counted" "docs: C headers: 3 declarations, 0 without a comment"
expect_status 1 "a function of a header without a comment fails" "$DOCS" --audit --headers "$F/Headers/bare"
expect_contains "… by name and line" "Tests/Fixtures/Docs/Headers/bare/fixture.h:11: [C] function fixture_quieter: no comment above it"

# The code of a catalog is compiled code.
expect_status 0 "a catalog whose Swift block is the region it names passes" "$DOCS" --audit --catalogs "$F/Catalog"
expect_contains "… counted" "docs: catalogs: 1 examples, 0 findings"
mkdir -p "$SCRATCH/catalog"; cp -R "$F/Catalog/DocFixture.docc" "$SCRATCH/catalog/"
sed -i '' 's/raised(by: 6)/raised(by: 12)/' "$SCRATCH/catalog/DocFixture.docc/DocFixture.md"
expect_status 1 "a block that is no longer the code of its region fails" "$DOCS" --audit --catalogs "$SCRATCH/catalog"
expect_contains "… with the difference" "+return quiet.raised(by: 12)"
cp "$F/Catalog/DocFixture.docc/DocFixture.md" "$SCRATCH/catalog/DocFixture.docc/DocFixture.md"
printf '\n```swift\nlet unchecked = Level(decibels: 0)\n```\n' >> "$SCRATCH/catalog/DocFixture.docc/DocFixture.md"
expect_status 1 "a Swift block that no compiled region backs fails" "$DOCS" --audit --catalogs "$SCRATCH/catalog"
expect_contains "… and says what to write" "a swift block that no compiled region backs"
cp "$F/Catalog/DocFixture.docc/DocFixture.md" "$SCRATCH/catalog/DocFixture.docc/DocFixture.md"
sed -i '' 's/#levels/#loudness/' "$SCRATCH/catalog/DocFixture.docc/DocFixture.md"
expect_status 1 "a marker of a region that does not exist fails" "$DOCS" --audit --catalogs "$SCRATCH/catalog"
expect_contains "… by name" "Tests/Fixtures/Docs/Clean/Clean.swift marks no region loudness"

# The documentation build, among stand-ins.
B="$SCRATCH/build"
mkdir -p "$B/bin"
cat > "$B/bin/xc" <<'EOS'
#!/bin/bash
echo "xc $*" >> "$STUB_LOG"
[ "${1:-}" = "device" ] && echo "FAKE-UDID"
exit 0
EOS
cat > "$B/bin/xcodebuild" <<'EOS'
#!/bin/bash
# Makes what docbuild makes: an archive per module, and the log on standard output.
echo "xcodebuild $*" >> "$STUB_LOG"
derived=""; while [ $# -gt 0 ]; do [ "$1" = "-derivedDataPath" ] && derived="$2"; shift; done
for module in $STUB_MODULES; do
    lower="$(printf '%s' "$module" | tr 'A-Z' 'a-z')"
    mkdir -p "$derived/Build/Products/Debug-iphonesimulator/$module.doccarchive/data/documentation/$lower"
    : > "$derived/Build/Products/Debug-iphonesimulator/$module.doccarchive/data/documentation/$lower.json"
    : > "$derived/Build/Products/Debug-iphonesimulator/$module.doccarchive/data/documentation/$lower/one.json"
done
# The landing page, with a link written as a path when STUB_LINK names one.
if [ -n "${STUB_LINK:-}" ]; then
    printf '{"references": {"%s": {"type": "link", "url": "%s"}}}\n' "$STUB_LINK" "$STUB_LINK" \
        > "$derived/Build/Products/Debug-iphonesimulator/ZTronDSP.doccarchive/data/documentation/ztrondsp.json"
fi
[ -n "${STUB_LOG_TEXT:-}" ] && printf '%b\n' "$STUB_LOG_TEXT"
exit "${STUB_STATUS:-0}"
EOS
cat > "$B/bin/docc" <<'EOS'
#!/bin/bash
# Merges as `docc merge` does, for what is read here: the pages of every archive in one archive.
echo "docc $*" >> "$STUB_LOG"
[ "${STUB_MERGE_STATUS:-0}" = "0" ] || { echo "Error: cannot merge"; exit "$STUB_MERGE_STATUS"; }
[ "${1:-}" = "merge" ] || exit 64
shift; output=""; inputs=()
while [ $# -gt 0 ]; do
    case "$1" in
        --output-path) output="$2"; shift ;;
        --synthesized-landing-page-*) shift ;;
        *) inputs+=("$1") ;;
    esac
    shift
done
mkdir -p "$output/data/documentation"
for input in "${inputs[@]}"; do cp -R "$input/data/documentation/." "$output/data/documentation/"; done
: > "$output/data/documentation.json"
EOS
chmod +x "$B/bin/xc" "$B/bin/xcodebuild" "$B/bin/docc"
export STUB_LOG="$B/log" STUB_MODULES="ZTronDSP ZTronDSPCore" ZTD_DOCS_XC="$B/bin/xc" ZTD_DOCS_XCODEBUILD="$B/bin/xcodebuild" ZTD_DOCS_DOCC="$B/bin/docc" ZTD_DOCS_DERIVED="$B/derived"
unset ZTD_CONFIG
WARNING="$ROOT/Sources/ZTronDSPCore/Pipeline/Pipeline.swift:12:9: warning: 'Missing' doesn't exist at '/ZTronDSPCore/Pipeline' (in target 'ZTronDSPCore' from project 'ZTronDSP')"
SDK_WARNING="/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/X.sdk/usr/include/x.h:1:1: warning: of the SDK"

: > "$STUB_LOG"
expect_status 0 "a documentation build without a warning for the package passes" env STUB_LOG_TEXT="$SDK_WARNING\n** BUILD DOCUMENTATION SUCCEEDED **" "$DOCS" --build
expect_contains "… and counts the pages of each module" "docs: ZTronDSPCore: 2 pages"
expect_contains "… in total" "docs: 2 archives, 4 pages, no warning for the package's sources"
expect_contains "a warning that names no file of the package is shown as a note" "docs: note, not of the package: $SDK_WARNING"
if grep -q -F -- "xcodebuild docbuild -scheme ZTronDSP-Package -destination platform=iOS Simulator,id=FAKE-UDID -derivedDataPath $B/derived -configuration Debug" "$STUB_LOG"; then
    pass "… built with docbuild, on the simulator of Scripts/xc.sh, into derived data of its own"
else
    fail "… built with docbuild, on the simulator of Scripts/xc.sh, into derived data of its own" "$(cat "$STUB_LOG")"
fi
expect_status 1 "a warning for the package's sources fails the build" env STUB_LOG_TEXT="$WARNING\n$WARNING" "$DOCS" --build
expect_contains "… and is printed, relative to the package" "docs: Sources/ZTronDSPCore/Pipeline/Pipeline.swift:12:9: warning: 'Missing' doesn't exist at '/ZTronDSPCore/Pipeline'"
if [ "$(printf '%s\n' "$LAST_OUTPUT" | grep -c "Pipeline.swift:12:9")" = "1" ]; then pass "… once, though the log has it twice"; else fail "… once, though the log has it twice" "$LAST_OUTPUT"; fi
expect_status 1 "a failed documentation build fails" env STUB_STATUS=65 STUB_LOG_TEXT="$ROOT/Sources/X.swift:1:1: error: nothing here" "$DOCS" --build
expect_contains "… with its errors" "error: nothing here"
expect_contains "… and its status" "the documentation build failed (xcodebuild exit 65)"
expect_status 1 "a build that made no archive fails" env STUB_MODULES="" "$DOCS" --build
expect_contains "… and says so" "the build made no documentation archive"

# The archives merged into one, where the landing page's links to the modules resolve.
: > "$STUB_LOG"
expect_status 0 "a link written as a path to a module that was built passes" env STUB_LINK="/documentation/ztrondspcore" "$DOCS" --build
expect_contains "… once the archives are merged into one" "1 link written as a path, each to a page of the archive"
if grep -q -F -- "docc merge $B/derived/Build/Products/Debug-iphonesimulator/ZTronDSP.doccarchive $B/derived/Build/Products/Debug-iphonesimulator/ZTronDSPCore.doccarchive --synthesized-landing-page-name ZTronDSP --synthesized-landing-page-kind Package --output-path $B/derived/ZTronDSP.doccarchive" "$STUB_LOG"; then
    pass "… every archive the build made, into derived data of the documentation"
else
    fail "… every archive the build made, into derived data of the documentation" "$(cat "$STUB_LOG")"
fi
expect_status 1 "a seeded link to a module without pages fails" env STUB_LINK="/documentation/ztrondspio" "$DOCS" --build
expect_contains "… and is named, with the page it is on" "docs: /documentation/ztrondsp links to /documentation/ztrondspio, which is no page of ${B#"$ROOT"/}/derived/ZTronDSP.doccarchive"
expect_contains "… and counted" "docs: 1 link to no page"
expect_status 1 "a merge that fails fails the build" env STUB_MERGE_STATUS=1 "$DOCS" --build
expect_contains "… and says so, with what docc printed" "the archives could not be merged into one:
    Error: cannot merge"
: > "$STUB_LOG"
expect_status 1 "the archives of a build with a warning are not merged" env STUB_LOG_TEXT="$WARNING" "$DOCS" --build
if grep -q "^docc" "$STUB_LOG"; then fail "… docc is not called" "$(cat "$STUB_LOG")"; else pass "… docc is not called"; fi

: > "$STUB_LOG"
expect_status 1 "--audit with --build runs both, the audit first" "$DOCS" --audit --build --graphs "$SCRATCH/bare/graphs" --sources "$F/Clean" --sources "$F/BareSymbol"
if printf '%s\n' "$LAST_OUTPUT" | grep -n -E "docs: 4 findings|docs: 2 archives" | sed -n '1s/:.*//p;2s/:.*//p' | awk 'NR == 1 { a = $1 } NR == 2 { exit !(a < $1) }'; then
    pass "… the audit's tally before the build's"
else
    fail "… the audit's tally before the build's" "$LAST_OUTPUT"
fi
unset STUB_LOG STUB_MODULES ZTD_DOCS_XC ZTD_DOCS_XCODEBUILD ZTD_DOCS_DOCC ZTD_DOCS_DERIVED

# Usage.
expect_status 2 "an unknown argument is refused" "$DOCS" --everything
expect_status 2 "a fixture option without --audit is refused" "$DOCS" --build --graphs "$SCRATCH/clean/graphs"
expect_status 2 "a folder that does not exist is refused" "$DOCS" --audit --sources "$SCRATCH/none"

# The package itself, when there is a build to read.
products="$("$ROOT/Scripts/xc.sh" products 2>/dev/null)"
if [ -d "$products/ZTronDSPCore.swiftmodule" ]; then
    expect_status 0 "the package's own audit passes" "$DOCS" --audit
else
    echo "  SKIP  the package's own audit: there is no build (Scripts/xc.sh build)"
fi
finish
