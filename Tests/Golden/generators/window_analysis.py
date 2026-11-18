"""Reference figures for the window analysis (WP-501d, WP-501f, STG-2).

Oracle: NumPy and SciPy, every argument explicit.

    gains       peak, coherent gain (the mean), noise gain (the mean square) and the equivalent
                noise bandwidth N·Σw² / (Σw)² of scipy.signal.get_window(…, fftbins=True)
    spectrum    the main-lobe width at −3 dB and between the first nulls, the highest side lobe,
                the scalloping loss and the side-lobe fall-off (Harris 1978), read from the
                transform of the window evaluated where each figure lies: a root of the half-power
                level (scipy.optimize.brentq) and bounded minimisations around the null and the
                lobes (scipy.optimize.minimize_scalar). See _spectral.window_figures_exact.
    overlap     scipy.signal.check_NOLA and check_COLA at a hop of a quarter and of half a frame,
                tol=1e-10

The package measures the spectral figures on a transform zero-padded sixteen times, with
interpolation; the tolerance of the comparison is 0.1 dB and 0.05 bin.

    python3 window_analysis.py
"""
import _golden
import _spectral

numpy, scipy = _golden.oracle()
from scipy import optimize, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"

WINDOWS = (
    ("rectangular", {}, lambda n: "boxcar"),
    ("hann", {}, lambda n: "hann"),
    ("hamming", {}, lambda n: "hamming"),
    ("blackman", {}, lambda n: "blackman"),
    ("blackmanHarris", {}, lambda n: "blackmanharris"),
    ("flatTop", {}, lambda n: "flattop"),
    ("kaiser", {"beta": 8.6}, lambda n: ("kaiser", 8.6)),
    ("gaussian", {"sigma": 0.15}, lambda n: ("gaussian", 0.15 * n)),
)

cases = []
for name, parameters, spelling in WINDOWS:
    for count in (64, 1024, 4096):
        w = signal.get_window(spelling(count), count, fftbins=True)
        total, energy = numpy.sum(w), numpy.sum(w * w)
        half, nulls, side, scalloping, fall_off = _spectral.window_figures_exact(numpy, optimize, w)
        overlap = []
        for hop in (count // 4, count // 2):
            overlap.append(1.0 if signal.check_NOLA(w, count, count - hop, tol=1e-10) else 0.0)
            overlap.append(1.0 if signal.check_COLA(w, count, count - hop, tol=1e-10) else 0.0)
        label = "-".join([name] + [f"{k}{v}" for k, v in parameters.items()] + [str(count)])
        cases.append(_golden.case(label, {
            "window": name, "count": count, **parameters,
            "hasNull": 1 if nulls is not None else 0, "hasSideLobe": 1 if side is not None else 0,
            "hasFallOff": 1 if fall_off is not None else 0},
            {"gains": _golden.real_vector([numpy.max(numpy.abs(w)), total / count, energy / count, count * energy / total ** 2]),
             "spectrum": _golden.real_vector([half, nulls if nulls is not None else 0.0, side if side is not None else 0.0,
                                              scalloping, fall_off if fall_off is not None else 0.0]),
             "overlap": _golden.real_vector(overlap)}))

_golden.write(TARGET, "window_analysis", cases)
