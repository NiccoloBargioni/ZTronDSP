#!/bin/bash
# Self-test of Scripts/api-digest.sh (WP-013).
#
# The fixture modules under Tests/Fixtures/APIDigest are compiled for the host, so the test
# reads real symbol graphs and needs neither a simulator nor a build of the package.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
F="$ROOT/Tests/Fixtures/APIDigest"
DIGEST="$ROOT/Scripts/api-digest.sh"
make_scratch api-digest-test
HOST="$(uname -m)-apple-macosx14.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"

compile() {   # <module name> <sources folder> <modules folder>
    xcrun swiftc -emit-module -module-name "$1" -package-name fixture -parse-as-library -swift-version 6 -target "$HOST" -sdk "$SDK" \
        -I "$3" -emit-module-path "$3/$1.swiftmodule" "$2"/*.swift 2>&1
}
graphs_of() { # <variant folder of FixtureDesign> <name of the scratch folder>
    mkdir -p "$SCRATCH/$2/modules" "$SCRATCH/$2/graphs"
    cp "$SCRATCH/core"/FixtureCore.* "$SCRATCH/$2/modules/"
    compile FixtureDesign "$F/$1" "$SCRATCH/$2/modules" || return 1
    for module in FixtureCore FixtureDesign; do
        xcrun swift-symbolgraph-extract -module-name "$module" -target "$HOST" -sdk "$SDK" -I "$SCRATCH/$2/modules" \
            -minimum-access-level public -omit-extension-block-symbols -skip-synthesized-members -output-dir "$SCRATCH/$2/graphs" 2>&1 || return 1
    done
}

echo "api-digest"
mkdir -p "$SCRATCH/core"
if ! output="$(compile FixtureCore "$F/FixtureCore" "$SCRATCH/core")"; then fail "the fixture core compiles" "$output"; finish; exit 1; fi
for pair in "FixtureDesign good" "FixtureDesignChanged changed" "FixtureDesignBad bad"; do
    set -- $pair
    if ! output="$(graphs_of "$1" "$2")"; then fail "the fixture module $1 compiles" "$output"; finish; exit 1; fi
done
pass "the fixture modules compile and their symbol graphs are extracted"

# The digest, and a seeded change of the API.
expect_status 0 "a digest is written from symbol graphs" "$DIGEST" --update --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
if grep -q -F "swift.init             Gain.init(decibels:isActive:) : init(decibels: Double, isActive: Bool = true)" "$SCRATCH/committed/FixtureDesign.txt" \
   && grep -q -F "conformance            LowPass : ResponseStage" "$SCRATCH/committed/FixtureDesign.txt" \
   && grep -q -F "conformance            Gain : FixtureCore.SequenceStage" "$SCRATCH/committed/FixtureDesign.txt"; then
    pass "… with declarations, default values and conformances"
else
    fail "… with declarations, default values and conformances" "$(cat "$SCRATCH/committed/FixtureDesign.txt")"
fi
if grep -q -E "internalOnly|packageOnlyHook|PackageOnlyType" "$SCRATCH/committed"/*.txt; then
    fail "… and nothing that is not public" "$(grep -E "internalOnly|packageOnlyHook|PackageOnlyType" "$SCRATCH/committed"/*.txt)"
else
    pass "… and nothing that is not public"
fi
expect_status 0 "the same API equals its digest" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
expect_status 1 "a seeded API change fails the check" "$DIGEST" --check --graphs "$SCRATCH/changed/graphs" --digests "$SCRATCH/committed"
expect_contains "… showing the symbol that was added" "+swift.func             addedLater() : func addedLater()"
expect_contains "… and the signature that changed" "+swift.init             Gain.init(decibels:floor:isActive:) : init(decibels: Double, floor: Double = -160, isActive: Bool = true)"
expect_contains "… against the committed one" "-swift.init             Gain.init(decibels:isActive:) : init(decibels: Double, isActive: Bool = true)"
rm "$SCRATCH/committed/FixtureCore.txt"
expect_status 1 "a module without a committed digest fails the check" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
expect_contains "… and is named" "FixtureCore has no committed digest"
"$DIGEST" --update --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed" >/dev/null
printf '# a digest of a module that no longer exists\n' > "$SCRATCH/committed/Removed.txt"
expect_status 1 "a committed digest without a module fails the check" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
"$DIGEST" --update --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed" >/dev/null
if [ ! -e "$SCRATCH/committed/Removed.txt" ]; then pass "an update removes the digest of a module that is gone"; else fail "an update removes the digest of a module that is gone"; fi

"$DIGEST" --update --graphs "$SCRATCH/bad/graphs" --digests "$SCRATCH/committed-bad" >/dev/null
if grep -q -F "conformance            FixtureCore.Pipeline : FixtureCore.SequenceStage" "$SCRATCH/committed-bad/FixtureDesign.txt" \
   && grep -q -F "conformance            Swift.Bool : ActivationSource" "$SCRATCH/committed/FixtureCore.txt"; then
    pass "a conformance added to another module's type is listed by that type's name"
else
    fail "a conformance added to another module's type is listed by that type's name" "$(grep conformance "$SCRATCH/committed-bad/FixtureDesign.txt" "$SCRATCH/committed/FixtureCore.txt")"
fi

# Stage initialisers end in `isActive:`.
expect_status 0 "stages whose initialisers end in isActive: pass" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
expect_contains "… the container and the environment reader being exempt" "4 public initialisers of 5 stage types end in \`isActive:\`"
expect_status 1 "a stage without isActive: fails the check" "$DIGEST" --check --graphs "$SCRATCH/bad/graphs" --digests "$SCRATCH/committed-bad"
expect_contains "an initialiser without the argument" "FixtureDesign: HighPass.init(cutoff:) takes no \`isActive:\`"
expect_contains "an initialiser where it is not last" "FixtureDesign: HighPass.init(cutoff:isActive:order:) takes \`isActive:\` before \`order:\`, which is not a trailing closure"
expect_contains "a stage through a refined protocol" "FixtureDesign: Shelf.init(gain:) takes no \`isActive:\`"
expect_contains "an initialiser added by an extension" "FixtureDesign: Gain.init(linear:) takes no \`isActive:\`"
expect_contains "… four of them, and no other" "4 stage initialisers without a trailing \`isActive:\`"
expect_lacks "isActive: before a trailing closure is accepted" "Tap.init"
expect_lacks "a type that is not a stage is left alone" "FilterDesign"
expect_lacks "the exempt container is left alone" "Pipeline.init"

# References to symbols that are not public.
expect_status 0 "sources that use public symbols only pass" "$DIGEST" --public-only FixtureDesign --sources "$F/FixtureDesign" \
    --import "$SCRATCH/core" --host --package-name fixture
expect_status 1 "a non-public Core reference fails" "$DIGEST" --public-only FixtureDesign --sources "$F/FixtureDesignLeaks" \
    --import "$SCRATCH/core" --host --package-name fixture
expect_contains "… naming the function" "packageOnlyHook"
expect_contains "… and the type" "PackageOnlyType"
mkdir -p "$SCRATCH/broken"; printf 'import FixtureCore\nlet broken: Int = "not a number"\n' > "$SCRATCH/broken/Broken.swift"
expect_status 2 "sources that do not compile at all are not mistaken for a leak" "$DIGEST" --public-only FixtureDesign --sources "$SCRATCH/broken" \
    --import "$SCRATCH/core" --host --package-name fixture
expect_contains "… the check says it could not run" "does not type-check under its own package name"

# Check 3: the map of the public API (WP-901a). A specification, a change request, two digests and
# a map of their own; each seeded fault is its own map, and each finding its own sentence.
M="$SCRATCH/map"
mkdir -p "$M/digests" "$M/changes"
cat > "$M/spec.md" <<'SPEC'
# A specification

## 4. Architecture

### 4.1 Stages

- **VC-4** A rule with a hyphen.
- **F5** A rule without one.

| Package | What |
|---|---|
| WP-204 | A row of the plan |

## Appendix A — parity

| Theirs | Ours |
|---|---|
| `one` | `Gain` |
| `two` | `Shelf` |
SPEC
printf '# CR-001 — A change request\n\n1. **An item.**\n2. **Additions to the public surface**: `Shelf`.\n' > "$M/changes/CR-001.md"
cat > "$M/digests/FixtureKit.txt" <<'KIT'
# FixtureKit — a digest
conformance            Gain : Swift.Sendable
swift.struct           Gain : struct Gain
swift.init             Gain.init(decibels:isActive:) : init(decibels: Double, isActive: Bool = true)
swift.protocol         Shelf : protocol Shelf
swift.method           Pipeline.gain(_:) : func gain(_ decibels: Double) -> Pipeline   [extends FixtureCore]
swift.func             nextFastLength(_:) : func nextFastLength(_ n: Int) -> Int
KIT
printf 'reexport               FixtureKit\n' > "$M/digests/FixtureFacade.txt"
row() { printf '%s\t%s\t%s\t%s\n' "$@"; }
clean_rows() {   # the six lines of a true map, a place of each kind
    row FixtureFacade "reexport FixtureKit" "§4.1" "the facade re-exports the kit"
    row FixtureKit Gain "App. A row 1" "a stage"
    row FixtureKit "Gain.init(decibels:isActive:)" VC-4 "a member the rule writes out"
    row FixtureKit Shelf "CR-001 item 2" "an addition"
    row FixtureKit "extension Pipeline.gain(_:)" F5 "a member added to a type of another module"
    row FixtureKit "nextFastLength(_:)" WP-204 "a function"
}
write_map() {    # <file>, the rows on standard input: a comment line, then the rows sorted
    { printf '# module\tsymbol\twhere listed\tnote\n'; LC_ALL=C sort; } > "$1"
}
map_check() {    # <map file>
    "$DIGEST" --spec-map --digests "$M/digests" --map "$1" --spec "$M/spec.md" --changes "$M/changes"
}
clean_rows | write_map "$M/clean.tsv"
expect_status 0 "a map that lists every public symbol at a place that exists passes" map_check "$M/clean.tsv"
expect_contains "… and counts its lines and their places" "lists every public symbol of 2 digests in 6 lines (5 at the specification, 1 at 1 change request)"

clean_rows | grep -v -F "	Shelf	" | write_map "$M/unlisted.tsv"
expect_status 1 "a public symbol the map does not list fails" map_check "$M/unlisted.tsv"
expect_contains "… naming the symbol" "api-digest: FixtureKit Shelf is public and the map does not list it:"
expect_contains "… with its digest line" "    swift.protocol         Shelf : protocol Shelf"
expect_contains "… and counting the unlisted" "1 public symbol without a line in"
clean_rows | grep -v -F "extension Pipeline" | grep -v -F "reexport" | write_map "$M/unlisted-kinds.tsv"
expect_status 1 "an unlisted member added to another module's type, and an unlisted re-export, fail" map_check "$M/unlisted-kinds.tsv"
expect_contains "… the member is named as an extension" "api-digest: FixtureKit extension Pipeline.gain(_:) is public and the map does not list it:"
expect_contains "… and the re-export as one" "api-digest: FixtureFacade reexport FixtureKit is public and the map does not list it:"
expect_lacks "a member of the module's own type needs no line" "FixtureKit Gain.init(decibels:isActive:) is public"

{ clean_rows; row FixtureKit Removed "§4.1" "gone from the digest"; row FixtureGone Thing "§4.1" "a module that is gone"; } | write_map "$M/stale.tsv"
expect_status 1 "a stale line fails" map_check "$M/stale.tsv"
expect_contains "… a symbol no digest holds" "FixtureKit Removed is in no digest (a stale line)"
expect_contains "… a module that has no digest" "FixtureGone Thing names a module that has no digest (a stale line)"

{
    row FixtureFacade "reexport FixtureKit" "internal detail" "not a place"
    row FixtureKit Gain "§9.9" "a section that does not exist"
    row FixtureKit "Gain.init(decibels:isActive:)" VC-99 "a rule that does not exist"
    row FixtureKit Shelf "CR-404" "a change request that does not exist"
    row FixtureKit "extension Pipeline.gain(_:)" "CR-001 item 9" "an item that does not exist"
    row FixtureKit "nextFastLength(_:)" "App. A row 3" "a row that does not exist"
} | write_map "$M/dead.tsv"
expect_status 1 "a dead clause fails" map_check "$M/dead.tsv"
expect_contains "… a section the specification does not have" "FixtureKit Gain is listed at §9.9, a section the specification does not have"
expect_contains "… a rule it does not define" "FixtureKit Gain.init(decibels:isActive:) is listed at VC-99, a rule or row the specification does not define"
expect_contains "… a change request that is not there" "FixtureKit Shelf names CR-404, which is not in"
expect_contains "… an item the change request does not have" "FixtureKit extension Pipeline.gain(_:) names item 9 of CR-001, which CR-001 does not have"
expect_contains "… a row past the end of Appendix A" "FixtureKit nextFastLength(_:) is listed at App. A row 3, but Appendix A has 2 rows"
expect_contains "… and words that are no place at all" "FixtureFacade reexport FixtureKit is listed at \"internal detail\", which is not a place"

{
    clean_rows | grep -v -F "reexport" | grep -v -F "	Shelf	"
    printf 'FixtureKit\tShelf\t\tan addition\n'
    row FixtureKit "nextFastLength(_:)" WP-204 "the same entry twice"
} | write_map "$M/format.tsv"
printf 'FixtureFacade\treexport FixtureKit\t§4.1\tafter the kit\nFixtureKit\tGain\t§4.1\n' >> "$M/format.tsv"
expect_status 1 "a line that breaks the format fails" map_check "$M/format.tsv"
expect_contains "… a line without a place" "FixtureKit Shelf has no place where it is listed"
expect_contains "… an entry listed twice" "FixtureKit nextFastLength(_:) has a line already"
expect_contains "… a line out of order" "FixtureFacade reexport FixtureKit is out of order: the map is sorted by module, then by symbol"
expect_contains "… a line of three columns" "a line has four columns separated by tabs (module, symbol, where it is listed, note); this one has 3"
expect_status 2 "a map check without its specification cannot run" "$DIGEST" --spec-map --digests "$M/digests" --map "$M/clean.tsv" \
    --spec "$M/absent.md" --changes "$M/changes"

expect_status 0 "a folder of digests without a map skips check 3 in --check" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed"
expect_contains "… and says so" "holds no spec-map.tsv, so check 3 (the map of the public API) is not run"
printf '# a map that lists nothing\n' > "$SCRATCH/committed/spec-map.tsv"
expect_status 1 "--check runs check 3 on the digests of the build" "$DIGEST" --check --graphs "$SCRATCH/good/graphs" --digests "$SCRATCH/committed" \
    --spec "$M/spec.md" --changes "$M/changes"
expect_contains "… and finds what the map does not list" "api-digest: FixtureDesign Gain is public and the map does not list it:"
rm "$SCRATCH/committed/spec-map.tsv"
expect_status 0 "the package's map lists every public symbol of its committed digests" "$DIGEST" --spec-map
expect_contains "… all ten of them" "lists every public symbol of 10 digests"

expect_status 2 "no mode is a usage error" "$DIGEST"
expect_status 2 "missing graphs are a usage error" "$DIGEST" --check --graphs "$SCRATCH/absent"

PRODUCTS="$("$ROOT/Scripts/xc.sh" products)"
if [ -d "$PRODUCTS/ZTronDSPCore.swiftmodule" ]; then
    expect_status 0 "the package's committed digests equal the last build" "$DIGEST" --check
    cp -R "$ROOT/Docs/API" "$SCRATCH/tampered"
    printf 'swift.func             removedFunction() : func removedFunction()\n' >> "$SCRATCH/tampered/ZTronDSPCore.txt"
    expect_status 1 "a committed digest that the build no longer matches fails" "$DIGEST" --check --digests "$SCRATCH/tampered" --skip-public-only
    expect_contains "… and the module is named" "the public API of ZTronDSPCore differs from its committed digest"
else
    echo "  SKIP  the package's own digests: there is no build at $PRODUCTS (run Scripts/xc.sh build)"
fi
finish
