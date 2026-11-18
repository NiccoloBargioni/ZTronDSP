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
