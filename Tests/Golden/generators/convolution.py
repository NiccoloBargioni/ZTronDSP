"""Golden vectors for the one-shot convolution and correlation (WP-513, WP-514, STG-2).

Oracles, as the table of STG-2 names them: numpy.convolve and scipy.signal.correlate, in double
precision on single-precision inputs, every argument explicit.

    convolution   numpy.convolve(x, h, mode)                           full, same, valid
    correlation   scipy.signal.correlate(x, y, mode, method="direct")  full, same, valid

Grid: lengths (16, 5), (1 024, 255), (48 000, 4 096), three modes each. numpy.convolve's "same"
has the length of the longer input; where the first input is the shorter one (5, 16) and
(255, 1 024) the oracle is scipy.signal.convolve(x, h, "same", method="direct"), whose result has
the length of the first input, which is the definition the package follows (and MATLAB's).

The normalisations of the correlation are not a library call. They are MATLAB's xcorr scale
options, written here from their definitions on the full result r[l] = sum_n x[n + l]·y[n]:

    biased        r[l] / max(N, M)
    unbiased      r[l] / (the number of products summed at lag l)   N - |l| for N = M
    coefficient   r[l] / sqrt(sum(x^2)·sum(y^2))

The results are written as Float32: the tolerance is 1e-5 of the largest output, a hundred
times what the rounding of a reference to single precision costs.

    python3 convolution.py
"""
import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
MODES = ("full", "same", "valid")
cases = []

rng = numpy.random.default_rng(20261513)
inputs = {}


def noise(count):
    """Seeded noise of a length, the same array wherever that length is asked for."""
    if count not in inputs:
        inputs[count] = (0.5 * rng.standard_normal(count)).astype(numpy.float32)
    return inputs[count]


def stored(count):
    return _golden.raw_array(TARGET, f"convolution_input_{count}.f32", noise(count), dtype="f32")


# --- Convolution -------------------------------------------------------------------------------------
for n, k in ((16, 5), (1024, 255), (48000, 4096)):
    x, h = noise(n).astype(numpy.float64), noise(k).astype(numpy.float64)
    for mode in MODES:
        result = numpy.convolve(x, h, mode=mode)
        cases.append(_golden.case(f"convolve-{n}-{k}-{mode}", {"n": n, "k": k, "mode": mode}, {
            "x": stored(n), "h": stored(k),
            "result": _golden.raw_array(TARGET, f"convolve_{n}_{k}_{mode}.f32", result, dtype="f32")}))

# The first input the shorter one: "same" keeps its length.
for n, k in ((5, 16), (255, 1024)):
    x, h = noise(n).astype(numpy.float64), noise(k).astype(numpy.float64)
    for mode in MODES:
        result = signal.convolve(x, h, mode=mode, method="direct")
        cases.append(_golden.case(f"convolve-{n}-{k}-{mode}", {"n": n, "k": k, "mode": mode}, {
            "x": stored(n), "h": stored(k),
            "result": _golden.raw_array(TARGET, f"convolve_{n}_{k}_{mode}.f32", result, dtype="f32")}))

# --- Correlation -------------------------------------------------------------------------------------
for n, m in ((16, 5), (1024, 255), (48000, 4096), (5, 16), (255, 1024)):
    x, y = noise(n).astype(numpy.float64), noise(m).astype(numpy.float64)
    for mode in MODES:
        result = signal.correlate(x, y, mode=mode, method="direct")
        cases.append(_golden.case(f"correlate-{n}-{m}-{mode}", {"n": n, "m": m, "mode": mode}, {
            "x": stored(n), "y": stored(m),
            "result": _golden.raw_array(TARGET, f"correlate_{n}_{m}_{mode}.f32", result, dtype="f32")}))

# --- The normalisations, from their definitions -------------------------------------------------------
for n, m in ((16, 5), (1024, 255), (255, 1024), (1024, 1024)):
    x, y = noise(n).astype(numpy.float64), noise(m).astype(numpy.float64)
    second = noise(m)
    if n == m:
        # Another signal of the same length, rounded to single precision as the test reads it.
        second = (numpy.roll(y, 37) * 0.8 + 0.1).astype(numpy.float32)
        y = second.astype(numpy.float64)
    full = signal.correlate(x, y, mode="full", method="direct")
    lags = signal.correlation_lags(n, m, mode="full")
    # y[k]·x[k + l] for every k both inputs hold.
    products = numpy.minimum(m - 1, n - 1 - lags) - numpy.maximum(0, -lags) + 1
    assert products.min() >= 1 and products.max() == min(n, m)
    values = {
        "x": stored(n),
        "y": stored(m) if n != m else _golden.raw_array(TARGET, f"correlate_second_{m}.f32", second, dtype="f32"),
        "none": _golden.raw_array(TARGET, f"correlate_{n}_{m}_none.f32", full, dtype="f32"),
        "biased": _golden.raw_array(TARGET, f"correlate_{n}_{m}_biased.f32", full / max(n, m), dtype="f32"),
        "unbiased": _golden.raw_array(TARGET, f"correlate_{n}_{m}_unbiased.f32", full / products, dtype="f32"),
        "coefficient": _golden.raw_array(TARGET, f"correlate_{n}_{m}_coefficient.f32",
                                         full / numpy.sqrt(numpy.sum(x * x) * numpy.sum(y * y)), dtype="f32"),
    }
    cases.append(_golden.case(f"normalized-{n}-{m}", {"n": n, "m": m, "mode": "full"}, values))

_golden.write(TARGET, "convolution", cases)
