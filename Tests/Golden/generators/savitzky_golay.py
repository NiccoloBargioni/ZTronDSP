"""Golden vectors for the Savitzky–Golay filter (WP-426, WP-427, STG-2).

Oracle: scipy.signal.savgol_coeffs for the coefficients, scipy.signal.savgol_filter for the
application.
Grid:   windows 5, 11, 31; orders 2, 3, 4; derivatives 0, 1, 2; the five edge modes.

The coefficients are in convolution order (use='conv'), with a sample spacing of 1. The filtered
signals are computed from a Float32 input of 96 samples (noise on a slow sine and a ramp, so that
the ends differ) and are stored as one raw Float32 matrix, one row per case:

    savitzky_golay_filtered.f32   [cases, 96]

A case of the filter names its row with the parameter `row`.

    python3 savitzky_golay.py
"""
import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPDesignTests"
WINDOWS = (5, 11, 31)
ORDERS = (2, 3, 4)
DERIVATIVES = (0, 1, 2)
MODES = ("interp", "mirror", "nearest", "constant", "wrap")
CONSTANT = 0.25
COUNT = 96


def fixture():
    generator = numpy.random.Generator(numpy.random.PCG64(20261115))
    n = numpy.arange(COUNT, dtype=float)
    values = 0.6 * numpy.sin(2.0 * numpy.pi * n / 37.0) + 0.004 * n - 0.3 + 0.1 * generator.standard_normal(COUNT)
    return values.astype(numpy.float32)


def main():
    cases = []
    for window in WINDOWS:
        for order in ORDERS:
            for derivative in DERIVATIVES:
                coefficients = signal.savgol_coeffs(window_length=window, polyorder=order, deriv=derivative, delta=1.0,
                                                    pos=None, use="conv")
                cases.append(_golden.case(f"coefficients-w{window}-p{order}-d{derivative}", {
                    "window": window, "order": order, "derivative": derivative},
                    {"coefficients": _golden.real_vector(coefficients)}))
    # A derivative above the polynomial order is identically zero.
    coefficients = signal.savgol_coeffs(window_length=7, polyorder=2, deriv=3, delta=1.0, pos=None, use="conv")
    cases.append(_golden.case("coefficients-w7-p2-d3", {"window": 7, "order": 2, "derivative": 3},
                              {"coefficients": _golden.real_vector(coefficients)}))

    x = fixture()
    rows = []
    for window in WINDOWS:
        for order in ORDERS:
            for derivative in DERIVATIVES:
                for mode in MODES:
                    y = signal.savgol_filter(x=x, window_length=window, polyorder=order, deriv=derivative, delta=1.0,
                                             axis=-1, mode=mode, cval=CONSTANT)
                    if y.dtype != numpy.float32:
                        raise ValueError("the oracle did not keep single precision")
                    cases.append(_golden.case(f"filter-w{window}-p{order}-d{derivative}-{mode}", {
                        "window": window, "order": order, "derivative": derivative, "mode": mode, "constant": CONSTANT,
                        "row": len(rows)}, {}))
                    rows.append(y)
    cases.append(_golden.case("signal", {"count": COUNT}, {
        "input": _golden.real_vector(x),
        "filtered": _golden.raw_array(TARGET, "savitzky_golay_filtered.f32", numpy.asarray(rows), dtype="f32")}))
    _golden.write(TARGET, "savitzky_golay", cases)


if __name__ == "__main__":
    main()
