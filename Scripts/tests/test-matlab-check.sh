#!/bin/bash
# Self-test of Scripts/lib/matlab_check.py, the static check of the golden MATLAB scripts (WP-910,
# MAT-2), which Scripts/golden.sh --check applies to every one of them.
#
# Every fixture under Tests/Fixtures/MATLAB/invalid holds one problem, and its first line says,
# after "% expect: ", what the check reports. The fixtures under valid/ pass, and the figure the
# check expects of every-statement.m is spelled out below (the Octave run of test-golden.sh
# compares it with what GNU Octave draws).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$ROOT/Scripts/tests/lib.sh"
CHECK="$ROOT/Scripts/lib/matlab_check.py"
FIXTURES="$ROOT/Tests/Fixtures/MATLAB"
make_scratch matlab-check-test

echo "matlab-check"
for fixture in "$FIXTURES"/valid/*.m; do
    expect_status 0 "valid/$(basename "$fixture") passes" python3 "$CHECK" "$fixture"
    expect_contains "… with no problem" "matlab-check: 1 script, 0 problems"
done

expect_status 0 "the figure every-statement.m draws can be printed" python3 "$CHECK" --model "$FIXTURES/valid/every-statement.m"
expect_contains "… one figure" "every-statement.m: figures 1"
expect_contains "… with one colorbar" "every-statement.m: colorbars 1"
expect_contains "… a panel with two lines and a stem, its grid on, its labels and its title" \
    "panel lines=2 stems=1 images=0 xscale=linear yscale=linear grid=on nextplot=replace xlabel='time (s)' ylabel='level (dB)' title=\"It's every statement\""
expect_contains "… a semilogx panel, its grid off" "panel lines=1 stems=0 images=0 xscale=log yscale=linear grid=off nextplot=replace xlabel='frequency (Hz)'"
expect_contains "… a loglog panel with two curves" "panel lines=2 stems=0 images=0 xscale=log yscale=log grid=off"
expect_contains "… an image" "panel lines=0 stems=0 images=1 xscale=linear yscale=linear grid=off nextplot=replace xlabel='column' ylabel='frequency (Hz)'"
expect_contains "… and a matrix plotted against a vector as one line per column" "panel lines=4 stems=0 images=0 xscale=linear yscale=linear grid=on nextplot=replace xlabel='real part'"

count=0
for fixture in "$FIXTURES"/invalid/*.m; do
    name="$(basename "$fixture")"
    expected="$(sed -n 's/^% expect: //p' "$fixture" | head -1)"
    if [ -z "$expected" ]; then
        fail "invalid/$name says what the check reports (a first line % expect: …)"
        continue
    fi
    expect_status 1 "invalid/$name fails" python3 "$CHECK" "$fixture"
    expect_contains "… with: $expected" "$expected"
    count=$((count + 1))
done
if [ "$count" -ge 30 ]; then pass "every rule has a fixture that breaks it ($count fixtures)"; else fail "every rule has a fixture that breaks it ($count fixtures)"; fi

scripts="$(ls "$ROOT"/Tests/*/Golden/*.m | wc -l | tr -d ' ')"
expect_status 0 "every committed golden script passes" python3 "$CHECK" "$ROOT"/Tests/*/Golden/*.m
expect_contains "… all $scripts of them" "matlab-check: $scripts scripts, 0 problems"
printf 'x = [1 2 3];\nplot(x, x);\nxlabel('"'"'time (s)'"'"');\nylabel('"'"'value'"'"');\n' > "$SCRATCH/two.m"
printf 'semilogz(1, 1);\n' > "$SCRATCH/one.m"
expect_status 1 "several scripts are checked in one call, and one problem fails it" python3 "$CHECK" "$SCRATCH/two.m" "$SCRATCH/one.m"
expect_contains "… which names the file and the line" "one.m:1: semilogz is not one of the commands of MAT-2"
expect_contains "… and counts" "matlab-check: 2 scripts, 1 problem"
: > "$SCRATCH/empty.m"
expect_status 1 "an empty script fails" python3 "$CHECK" "$SCRATCH/empty.m"
expect_contains "… and says so" "the script is empty"
printf 'x = 1;\r\n' > "$SCRATCH/crlf.m"
expect_status 1 "a carriage return fails" python3 "$CHECK" "$SCRATCH/crlf.m"
expect_contains "… and says so" "the script holds a carriage return"
expect_status 1 "a file that does not exist fails" python3 "$CHECK" "$SCRATCH/absent.m"
expect_contains "… and says so" "absent.m: cannot be read"
expect_status 2 "no file is a usage error" python3 "$CHECK"
expect_status 2 "an unknown option is a usage error" python3 "$CHECK" --everything "$SCRATCH/two.m"
finish
