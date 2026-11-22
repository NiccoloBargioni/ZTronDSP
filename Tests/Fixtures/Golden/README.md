Generators that exist only for the self-test of `Scripts/golden.sh`. The test copies them, one
case at a time, into a scratch tree beside the real `_oracle.py`, `_golden.py` and `buttap.py`.
`Scripts/generate-stress-fixtures.py` here is a stand-in for the script of the same name that
the runner treats as one more generator.

`needs_librosa.py` loads librosa the way every librosa generator does (`_golden.librosa()`). The
self-test runs it with the librosa that is installed, and with stand-ins for librosa that it puts
first on `PYTHONPATH`: one whose version is not the pin (the run is refused), one whose import fails
the way it fails where librosa is not installed (the generator is pending), and one that is
installed and cannot be loaded (the run is refused). `cross_check_fails.py` proves that
`_golden.cross_check` stops a generator before it writes.
