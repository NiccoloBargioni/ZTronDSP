MATLAB scripts for the self-tests of `Scripts/lib/matlab_check.py` (the static check that
`Scripts/golden.sh --check` applies to every golden script) and of `Scripts/golden.sh --octave`
(the run of every golden script under GNU Octave), WP-910.

- `valid/`: scripts that pass the static check and run under Octave with the figure the check
  expects. `every-statement.m` holds every kind of statement the writer makes, and a few it does
  not (function syntax of `hold` and `grid`, a transpose, a comment after a statement).
- `invalid/`: one problem per script. The first line, `% expect: …`, is what the static check
  reports; a second line, `% octave: …`, is what Octave prints when it runs the script, for the
  problems that stop or warn Octave too. The others are scripts that Octave runs and the rules of
  MAT-2 refuse (no axis labels, data after the plots, a function outside core MATLAB).

`Scripts/tests/test-matlab-check.sh` runs the static check on each; `Scripts/tests/test-golden.sh`
runs the ones marked `% octave:` under Octave, when it is installed.
