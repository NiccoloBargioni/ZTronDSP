"""The speech and music fixtures as raw files for the analysis tests (STG-2).

The specification names "the speech and music fixtures" and supplies none. These are synthetic
and deterministic (see _fixtures.py): the same samples on every run, written as little-endian
Float32 beside a JSON that names them, so the Swift tests and the generators that compute
references from them read the same signal.

    python3 fixtures.py
"""
import _golden
import _fixtures

numpy, scipy = _golden.oracle()

TARGET = "ZTronDSPAnalysisTests"
cases = []
for name, samples in (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy))):
    cases.append(_golden.case(
        name, {"sampleRate": _fixtures.SAMPLE_RATE, "count": int(samples.shape[0])},
        {"samples": _golden.raw_array(TARGET, f"fixture_{name}.f32", samples, dtype="f32")}))

_golden.write(TARGET, "fixtures", cases)
