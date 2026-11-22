#!/bin/bash
# Self-test of Scripts/golden.sh (WP-007).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
GOLDEN="$ROOT/Scripts/golden.sh"
FIXTURES="$ROOT/Tests/Fixtures/Golden"
make_scratch golden-test
TREE="$SCRATCH/tree"
GENERATORS="$TREE/Tests/Golden/generators"
VECTOR="$TREE/Tests/ZTronDSPDesignTests/Golden/buttap.json"

fresh_tree() {    # a scratch tree with the real helpers, the real buttap generator, its vector and a manifest of just that
    reset_folder "$TREE"
    mkdir -p "$GENERATORS" "$TREE/Tests/ZTronDSPDesignTests/Golden"
    cp "$ROOT/Tests/Golden/generators/_oracle.py" "$ROOT/Tests/Golden/generators/_golden.py" \
       "$ROOT/Tests/Golden/generators/requirements.txt" "$ROOT/Tests/Golden/generators/buttap.py" "$GENERATORS/"
    cp "$ROOT/Tests/ZTronDSPDesignTests/Golden/buttap.json" "$VECTOR"
    printf 'Golden vectors used by this test target.\n' > "$TREE/Tests/ZTronDSPDesignTests/Golden/README.txt"
    "$GOLDEN" --only buttap --root "$TREE" >/dev/null 2>&1 || { echo "the scratch tree could not be prepared" >&2; exit 1; }
}
add() { cp "$FIXTURES/generators/$1.py" "$GENERATORS/"; }
ulp_away='s/"re":\[-0.7071067811865476,-0.7071067811865476\]/"re":[-0.7071067811865476,-0.7071067811865477]/'
far_away='s/"re":\[-0.7071067811865476,-0.7071067811865476\]/"re":[-0.7071067811865476,-0.7071067811]/'

echo "golden"
expect_status 0 "the committed files match the manifest" "$GOLDEN" --check
expect_contains "… and the check says how many" "match the manifest"
fresh_tree
expect_status 0 "a scratch tree with the committed generator matches too" "$GOLDEN" --check --root "$TREE"
if cmp -s "$VECTOR" "$ROOT/Tests/ZTronDSPDesignTests/Golden/buttap.json"; then pass "… and regenerating there rewrote the committed vector byte for byte"; else fail "… and regenerating there rewrote the committed vector byte for byte"; fi
expect_contains "a README.txt in a Golden folder is not a vector" "1 file of 1 generator match the manifest"

# The manifest check fails on a changed vector.
sed -i '' "$ulp_away" "$VECTOR"
expect_status 1 "a changed vector fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "Tests/ZTronDSPDesignTests/Golden/buttap.json is not the file the manifest recorded"
fresh_tree; rm "$VECTOR"
expect_status 1 "a missing vector fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "buttap.json is listed in the manifest and does not exist"
fresh_tree; printf '{}\n' > "$TREE/Tests/ZTronDSPDesignTests/Golden/stray.json"
expect_status 1 "a vector file the manifest does not list fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "Tests/ZTronDSPDesignTests/Golden/stray.json is a vector file that the manifest does not list"
expect_status 1 "… and a full run says no generator wrote it" "$GOLDEN" --root "$TREE"
expect_contains "… by name" "stray.json was written by no generator"
fresh_tree; printf '\n# a later edit\n' >> "$GENERATORS/buttap.py"
expect_status 1 "a generator edited after it was run fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and says what to run" "buttap.py changed after it was last run: run Scripts/golden.sh --only buttap"
fresh_tree; add raw_vectors
expect_status 1 "a generator that was never run fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "the generator raw_vectors (Tests/Golden/generators/raw_vectors.py) is not in the manifest"
fresh_tree; rm "$GENERATORS/buttap.py"
expect_status 1 "vectors whose generator is gone fail the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and say so" "the manifest lists files of buttap, and there is no such generator"
fresh_tree; printf 'def helper():\n    return 1\n' > "$GENERATORS/_helper.py"; printf 'raise SystemExit("not a generator")\n' > "$GENERATORS/Upper.py"
expect_status 0 "a helper (leading underscore) and a file that is not [a-z]*.py are not generators" "$GOLDEN" --root "$TREE"

fresh_tree; sed -i '' 's/^scipy==.*/scipy==0.0.0/' "$GENERATORS/requirements.txt"
expect_status 1 "pins that differ from the manifest's fail the check" "$GOLDEN" --check --root "$TREE"
expect_status 2 "running with an oracle that differs from its pin is refused" "$GOLDEN" --root "$TREE"
expect_contains "… with both versions" "is installed and 0.0.0 is pinned"

# Re-running reproduces the committed vectors.
fresh_tree
expect_status 0 "regenerating reproduces the committed vectors" "$GOLDEN" --reproduce --root "$TREE"
expect_contains "… bit for bit" "buttap reproduces its committed files bit for bit"
expect_contains "the run log names the oracles" "golden: oracles numpy"
if python3 -c "import sys; sys.path.insert(0, '$ROOT/Tests/Golden/generators'); import _oracle; _oracle.load(); sys.exit(0 if _oracle.replaced else 1)" 2>/dev/null; then
    expect_contains "… and the stand-ins that are in use on this host" "golden: stand-ins are in place of"
fi
sed -i '' "$ulp_away" "$VECTOR"
expect_status 0 "a committed vector one unit in the last place away is within tolerance" "$GOLDEN" --reproduce --root "$TREE"
expect_contains "… and is reported as not bit for bit" "(not bit for bit)"
sed -i '' 's/"re":\[-0.7071067811865476,-0.7071067811865477\]/"re":[-0.7071067811865476,-0.7071067811]/' "$VECTOR"
expect_status 1 "a committed vector that differs by more does not reproduce" "$GOLDEN" --reproduce --root "$TREE"
expect_contains "… and the case is named" "case order-2, poles: deviates by"
fresh_tree
before="$(shasum -a 256 "$VECTOR" "$TREE/Tests/Golden/manifest.json")"
expect_status 0 "a second full run succeeds" "$GOLDEN" --root "$TREE"
after="$(shasum -a 256 "$VECTOR" "$TREE/Tests/Golden/manifest.json")"
if [ "$before" = "$after" ]; then pass "… and rewrites the same vector and the same manifest"; else fail "… and rewrites the same vector and the same manifest" "$before
$after"; fi

# Every value shape, raw files included.
fresh_tree; add raw_vectors
expect_status 0 "a generator with raw files runs" "$GOLDEN" --only raw_vectors --root "$TREE"
RAW="$TREE/Tests/ZTronDSPCoreTests/Golden"
sizes="$(stat -f '%z' "$RAW/raw_vectors.long.f64" "$RAW/raw_vectors.long32.f32" "$RAW/raw_vectors.matrix.f64" 2>&1 | tr '\n' ' ')"
if [ "$sizes" = "65536 32768 96 " ]; then pass "… and writes little-endian f64 and f32 files of the right length beside the JSON"; else fail "… and writes little-endian f64 and f32 files of the right length beside the JSON" "$sizes"; fi
if grep -q '"matrix":{"raw":"raw_vectors.matrix.f64","shape":\[3,4\]}' "$RAW/raw_vectors.json"; then pass "… with their shape in the JSON"; else fail "… with their shape in the JSON" "$(head -c 400 "$RAW/raw_vectors.json")"; fi
if [ "$(grep -c '"path": "Tests/ZTronDSPCoreTests/Golden/raw_vectors' "$TREE/Tests/Golden/manifest.json")" = "6" ]; then pass "… and the manifest lists the JSON and its five raw files under that generator"; else fail "… and the manifest lists the JSON and its five raw files under that generator" "$(cat "$TREE/Tests/Golden/manifest.json")"; fi
expect_status 0 "… and the check accepts the tree" "$GOLDEN" --check --root "$TREE"
expect_status 0 "… and it reproduces" "$GOLDEN" --reproduce --only raw_vectors --root "$TREE"
printf '\0' | dd of="$RAW/raw_vectors.long.f64" bs=1 seek=100 conv=notrunc 2>/dev/null
expect_status 1 "a changed raw file fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "raw_vectors.long.f64 is not the file the manifest recorded"
expect_status 1 "… and does not reproduce" "$GOLDEN" --reproduce --only raw_vectors --root "$TREE"
expect_contains "… with the value that deviates" "case shapes, long: deviates by"

fresh_tree; add two_documents
expect_status 0 "one script may write several vector files" "$GOLDEN" --root "$TREE"
if [ "$(grep -c '"path": "Tests/ZTronDSPCoreTests/Golden/two_documents_' "$TREE/Tests/Golden/manifest.json")" = "2" ]; then pass "… and both belong to it in the manifest"; else fail "… and both belong to it in the manifest" "$(cat "$TREE/Tests/Golden/manifest.json")"; fi
expect_status 0 "… and the check accepts them" "$GOLDEN" --check --root "$TREE"

# OUTPUTS: files a generator writes outside the Golden folders.
fresh_tree; add extra_outputs
expect_status 0 "a generator that writes a Swift file and declares it runs" "$GOLDEN" --root "$TREE"
if grep -q '"path": "Tests/CZTronDSPTests/KernelFixtures.swift"' "$TREE/Tests/Golden/manifest.json"; then pass "… and the manifest covers the declared output"; else fail "… and the manifest covers the declared output" "$(cat "$TREE/Tests/Golden/manifest.json")"; fi
expect_status 0 "… and the check accepts it" "$GOLDEN" --check --root "$TREE"
expect_status 0 "… and it reproduces" "$GOLDEN" --reproduce --root "$TREE"
printf '// edited by hand\n' >> "$TREE/Tests/CZTronDSPTests/KernelFixtures.swift"
expect_status 1 "a declared output edited by hand fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "Tests/CZTronDSPTests/KernelFixtures.swift is not the file the manifest recorded"
expect_status 1 "… and does not reproduce" "$GOLDEN" --reproduce --only extra_outputs --root "$TREE"
expect_contains "… as a file that must match byte for byte" "KernelFixtures.swift differs, and it is not a vector file"
fresh_tree; add declares_unwritten
expect_status 1 "a generator that declares an output it does not write fails" "$GOLDEN" --only declares_unwritten --root "$TREE"
expect_contains "… and the output is named" "it declares OUTPUTS that it did not write: Tests/CZTronDSPTests/NeverWritten.swift"
fresh_tree; add writes_nothing
expect_status 1 "a generator that writes nothing fails" "$GOLDEN" --only writes_nothing --root "$TREE"
expect_contains "… and says so" "it wrote nothing into a Golden folder and declares no OUTPUTS"

# Scripts/generate-stress-fixtures.py is one more generator.
fresh_tree; mkdir -p "$TREE/Scripts"; cp "$FIXTURES/Scripts/generate-stress-fixtures.py" "$TREE/Scripts/"
expect_status 1 "the stress-fixture script is a generator that the check expects in the manifest" "$GOLDEN" --check --root "$TREE"
expect_contains "… by name" "the generator generate-stress-fixtures (Scripts/generate-stress-fixtures.py) is not in the manifest"
expect_status 0 "a full run invokes it" "$GOLDEN" --root "$TREE"
if grep -q '"path": "Sources/ZTronDSPTesting/StressFixtureData.swift"' "$TREE/Tests/Golden/manifest.json"; then pass "… and the manifest covers Sources/ZTronDSPTesting/StressFixtureData.swift"; else fail "… and the manifest covers Sources/ZTronDSPTesting/StressFixtureData.swift" "$(cat "$TREE/Tests/Golden/manifest.json")"; fi
expect_status 0 "… and the check accepts it" "$GOLDEN" --check --root "$TREE"
expect_status 0 "… and it reproduces" "$GOLDEN" --reproduce --root "$TREE"
printf '// edited by hand\n' >> "$TREE/Sources/ZTronDSPTesting/StressFixtureData.swift"
expect_status 1 "the generated source edited by hand fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… and is named" "Sources/ZTronDSPTesting/StressFixtureData.swift is not the file the manifest recorded"

# No NaN, no infinity.
fresh_tree; add emits_nan
expect_status 1 "a generator that produces a NaN fails" "$GOLDEN" --only emits_nan --root "$TREE"
expect_contains "… with the reason" "a golden vector holds a non-finite value"
if [ ! -e "$TREE/Tests/ZTronDSPCoreTests/Golden/emits_nan.json" ]; then pass "… and writes no vector"; else fail "… and writes no vector"; fi

# An oracle that is pinned and not installed.
fresh_tree; add needs_missing
expect_status 1 "a generator that needs a module nobody pinned simply fails" "$GOLDEN" --only needs_missing --root "$TREE"
expect_contains "… with Python's words" "No module named 'ztd_oracle_that_is_not_installed'"
printf 'ztd-oracle-that-is-not-installed==1.0.0\n' >> "$GENERATORS/requirements.txt"
expect_status 0 "a generator whose pinned oracle is not installed does not stop the others" "$GOLDEN" --root "$TREE"
expect_contains "… and is recorded as pending" "PENDING needs_missing: ztd-oracle-that-is-not-installed is not installed"
expect_contains "… while the others ran" "golden: buttap: Tests/ZTronDSPDesignTests/Golden/buttap.json"
expect_status 0 "the check reports a pending generator loudly" "$GOLDEN" --check --root "$TREE"
expect_contains "… by name" "golden: PENDING needs_missing"
expect_status 3 "the strict check fails on a pending generator" "$GOLDEN" --check --strict --root "$TREE"

expect_status 2 "an unknown generator is a usage error" "$GOLDEN" --only nothing --root "$TREE"
expect_status 2 "a tree without generators is a usage error" "$GOLDEN" --check --root "$SCRATCH"

# The golden MATLAB scripts (WP-910): the static check of --check, and the run under GNU Octave.
MATLAB="$ROOT/Tests/Fixtures/MATLAB"
fresh_tree; cp "$MATLAB/invalid/not-a-command.m" "$TREE/Tests/ZTronDSPDesignTests/Golden/stray.m"
expect_status 1 "a golden MATLAB script that fails the static check fails the check" "$GOLDEN" --check --root "$TREE"
expect_contains "… with the line and the problem" "Tests/ZTronDSPDesignTests/Golden/stray.m:4: semilogz is not one of the commands of MAT-2"
expect_contains "… and a golden script that no generator wrote is named too" "stray.m is a golden MATLAB script that the manifest does not list"
expect_status 1 "… and a full run says no generator wrote it" "$GOLDEN" --root "$TREE"
expect_contains "… by name" "stray.m was written by no generator"

OCTAVE_TREE="$SCRATCH/octave-tree"
octave_tree() {   # <fixture>…: a tree whose only golden files are these scripts
    reset_folder "$OCTAVE_TREE"
    mkdir -p "$OCTAVE_TREE/Tests/Golden/generators" "$OCTAVE_TREE/Tests/ZTronDSPCoreTests/Golden"
    cp "$@" "$OCTAVE_TREE/Tests/ZTronDSPCoreTests/Golden/"
}
# A stand-in for GNU Octave on the PATH: it logs how it was called, keeps the function through which
# the runner sources a script, and answers as STANDIN_MODE says.
STANDINS="$SCRATCH/standins"; mkdir -p "$STANDINS"
export STANDIN_LOG="$SCRATCH/octave.log" STANDIN_KEEP="$SCRATCH/kept"
mkdir -p "$STANDIN_KEEP"
cat > "$STANDINS/octave" <<'EOS'
#!/bin/bash
if [ "${1:-}" = "--version" ]; then echo "GNU Octave (stand-in) version 0.0-standin"; exit 0; fi
printf 'QT_QPA_PLATFORM=%s %s\n' "${QT_QPA_PLATFORM:-}" "$*" >> "$STANDIN_LOG"
helpers="$(printf '%s' "$*" | sed -n -E "s/.*addpath \('([^']*)'\).*/\1/p")"
[ -n "$helpers" ] && cp "$helpers/ztd_run.m" "$STANDIN_KEEP/" 2>/dev/null
case "${STANDIN_MODE:-}" in
    silent) exit 0 ;;
    failing) echo "error: 'semilogz' undefined" >&2; exit 1 ;;
    warning) printf 'ZTD-FIGURES\t0\nZTD-OCTAVE-DONE\n'; echo "warning: axis: omitting non-positive data in log plot" >&2; exit 0 ;;
    nothing) printf 'ZTD-FIGURES\t0\nZTD-OCTAVE-DONE\n'; exit 0 ;;
esac
exit 0
EOS
chmod +x "$STANDINS/octave"
printf '%% A script that defines its data and plots nothing.\nx = [1 2 3];\n' > "$SCRATCH/plots-nothing.m"

octave_tree "$SCRATCH/plots-nothing.m"
expect_status 0 "a run whose Octave exits 0, warns of nothing and reports the figure the script draws passes" env STANDIN_MODE=nothing PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… and names the script" "ran under Octave: Tests/ZTronDSPCoreTests/Golden/plots-nothing.m: exit 0, no error and no warning, no figure"
expect_contains "… and the Octave it ran" "golden: GNU Octave 0.0-standin ($STANDINS/octave)"
if grep -q -F -- "QT_QPA_PLATFORM=offscreen --no-gui --quiet --norc --no-history --eval addpath (" "$STANDIN_LOG"; then pass "Octave is run without its window, without the user's start-up files, offscreen"; else fail "Octave is run without its window, without the user's start-up files, offscreen" "$(cat "$STANDIN_LOG")"; fi
if grep -q -F "ztd_run ('$OCTAVE_TREE/Tests/ZTronDSPCoreTests/Golden/plots-nothing.m'); ztd_figure_report (); printf ('ZTD-OCTAVE-DONE\n');" "$STANDIN_LOG"; then pass "… and sources the script through the runner's function, then reports the figure"; else fail "… and sources the script through the runner's function, then reports the figure" "$(cat "$STANDIN_LOG")"; fi
visible="$(grep -n "set (0, 'defaultfigurevisible', 'off');" "$STANDIN_KEEP/ztd_run.m" | cut -d: -f1)"; sourced="$(grep -n "source (ztd_script);" "$STANDIN_KEEP/ztd_run.m" | cut -d: -f1)"
if [ -n "$visible" ] && [ -n "$sourced" ] && [ "$visible" -lt "$sourced" ]; then pass "… which sets the default figure visibility off before it sources the script, unchanged"; else fail "… which sets the default figure visibility off before it sources the script, unchanged" "$(cat "$STANDIN_KEEP/ztd_run.m" 2>&1)"; fi
expect_status 1 "a run that warns fails" env STANDIN_MODE=warning PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… and says why" "FAILED under Octave: Tests/ZTronDSPCoreTests/Golden/plots-nothing.m: Octave reported 1 error or warning"
expect_contains "… with Octave's words" "stderr: warning: axis: omitting non-positive data in log plot"
expect_status 1 "a run that stops with an error fails" env STANDIN_MODE=failing PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… with the status and the error" "Octave exited with status 1; Octave reported 1 error or warning"
expect_status 1 "a run that does not reach its end fails" env STANDIN_MODE=silent PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… and says so" "the run did not reach its end (ZTD-OCTAVE-DONE was not printed)"
octave_tree "$MATLAB/valid/every-statement.m"
expect_status 1 "a run that does not draw what the script draws fails: the plot commands must execute" env STANDIN_MODE=nothing PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… and says so" "the figure Octave drew is not the one the script draws"
expect_contains "… with the figure expected" "expected: figures 1"
expect_contains "… and the one drawn" "drawn:    figures 0"
PYTHON="$(python3 -c 'import sys; print(sys.executable)')"     # the interpreter itself, not a shim that needs the PATH
expect_status 3 "without Octave on the PATH the run is skipped" env PATH="" "$PYTHON" "$ROOT/Scripts/lib/golden_runner.py" --octave --root "$OCTAVE_TREE"
expect_contains "… loudly, with how many scripts were not run" "golden: SKIPPED: GNU Octave is not installed (no octave on the PATH): the 1 golden MATLAB script was not run under Octave"
expect_status 3 "… also when the PATH holds no Octave but other tools" env PATH="/usr/bin:/bin" "$PYTHON" "$ROOT/Scripts/lib/golden_runner.py" --octave --root "$OCTAVE_TREE"
reset_folder "$OCTAVE_TREE"; mkdir -p "$OCTAVE_TREE/Tests/Golden/generators"
expect_status 0 "a tree without golden scripts runs nothing" env STANDIN_MODE=nothing PATH="$STANDINS:$PATH" "$GOLDEN" --octave --root "$OCTAVE_TREE"
expect_contains "… and says so" "there is no golden MATLAB script to run under Octave"

# GNU Octave itself, when it is installed: the package's golden scripts, the valid fixture, and the
# fixtures whose problem stops or warns Octave (a wrong plot command among them) fail.
if command -v octave >/dev/null 2>&1 && octave --version 2>/dev/null | head -1 | grep -q "GNU Octave"; then
    expect_status 0 "GNU Octave: every golden script of the package runs, and draws what it says" "$GOLDEN" --octave
    expect_contains "… all of them" "golden MATLAB scripts ran under GNU Octave as they draw"
    octave_tree "$MATLAB/valid/every-statement.m"
    expect_status 0 "GNU Octave: the script with every kind of statement runs and draws what the static check expects" "$GOLDEN" --octave --root "$OCTAVE_TREE"
    expect_contains "… five panels, one colorbar" "1 figure: 5 axes (9 lines, 1 stem, 1 image), 1 colorbar"
    for fixture in $(grep -l '^% octave: ' "$MATLAB"/invalid/*.m); do
        expected="$(sed -n 's/^% octave: //p' "$fixture" | head -1)"
        octave_tree "$fixture"
        expect_status 1 "GNU Octave: invalid/$(basename "$fixture") fails" "$GOLDEN" --octave --root "$OCTAVE_TREE"
        expect_contains "… with Octave's words: $expected" "$expected"
    done
else
    echo "  SKIP  GNU Octave is not installed: the golden scripts and the fixtures were not run under it (brew install octave)"
fi
expect_status 0 "after all of this the package's own files still match the manifest" "$GOLDEN" --check
finish
