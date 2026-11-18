Generators that exist only for the self-test of `Scripts/golden.sh`. The test copies them, one
case at a time, into a scratch tree beside the real `_oracle.py`, `_golden.py` and `buttap.py`.
`Scripts/generate-stress-fixtures.py` here is a stand-in for the script of the same name that
the runner treats as one more generator.
