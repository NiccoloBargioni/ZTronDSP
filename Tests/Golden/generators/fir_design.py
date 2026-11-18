"""Golden vectors for FIR design (WP-423, WP-425, STG-2).

Oracle: scipy.signal.firwin and kaiserord for the windowed sinc; scipy.signal.firls for the
least-squares fit.
Grid:   four responses; lengths 31, 101, 255; Hann and Kaiser windows (STG-2), and two even
        lengths for the responses that are zero at the Nyquist frequency.

The least-squares method of the package fits the whole axis, with a straight line across each
transition band (§6.3.3); the oracle is called with exactly those bands. The fixtures named
`gap-…` leave part of the axis out, as the `LeastSquares` element of an FIR system may: their
normal equations lose their rank in double precision, SciPy takes its own fall-back for them
(lstsq), and their taps are no longer determined to the tolerance of the others. They carry the
bands, so that a test can compare what is determined: the error of the fit.

    python3 fir_design.py
"""
import math
import warnings

import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPDesignTests"
FS = 48000.0
EDGES = {"lowpass": [4000.0], "highpass": [4000.0], "bandpass": [3000.0, 9000.0], "bandstop": [3000.0, 9000.0]}
WINDOWS = {"hann": "hann", "kaiser": ("kaiser", 8.6)}
TRANSITION = 1200.0


def windowed_sinc(cases):
    for response, edges in EDGES.items():
        lengths = [31, 101, 255] + ([32, 100] if response in ("lowpass", "bandpass") else [])
        for length in lengths:
            for name, window in WINDOWS.items():
                taps = signal.firwin(numtaps=length, cutoff=edges, width=None, window=window, pass_zero=response,
                                     scale=True, fs=FS)
                parameters = {"response": response, "edges": edges, "length": length, "window": name, "sample_rate": FS}
                if name == "kaiser":
                    parameters["beta"] = window[1]
                cases.append(_golden.case(f"firwin-{response}-{length}-{name}", parameters, {"taps": _golden.real_vector(taps)}))
    # A Kaiser window chosen from the transition width (firwin's `width`), as `.windowedSinc()`
    # does when a filter states a transition and no attenuation.
    for response, edges in EDGES.items():
        taps = signal.firwin(numtaps=101, cutoff=edges, width=TRANSITION, window="hamming", pass_zero=response,
                             scale=True, fs=FS)
        cases.append(_golden.case(f"firwin-{response}-101-width", {
            "response": response, "edges": edges, "length": 101, "window": "width", "transition": TRANSITION,
            "sample_rate": FS}, {"taps": _golden.real_vector(taps)}))
    # A Kaiser window chosen for 80 dB: the default of `.windowedSinc()`.
    beta = signal.kaiser_beta(a=80.0)
    taps = signal.firwin(numtaps=101, cutoff=EDGES["lowpass"], width=None, window=("kaiser", beta), pass_zero="lowpass",
                         scale=True, fs=FS)
    cases.append(_golden.case("firwin-lowpass-101-default", {
        "response": "lowpass", "edges": EDGES["lowpass"], "length": 101, "window": "default", "beta": float(beta),
        "sample_rate": FS}, {"taps": _golden.real_vector(taps)}))


def kaiser_estimates(cases):
    for attenuation in (8.0, 21.5, 40.0, 60.0, 80.0, 100.0, 120.0):
        for width in (0.01, 0.05, 0.2):       # in units of the Nyquist frequency
            length, beta = signal.kaiserord(ripple=attenuation, width=width)
            cases.append(_golden.case(f"kaiserord-{attenuation:g}-{width:g}", {
                "attenuation": attenuation, "width": width, "length": int(length)}, {"beta": _golden.real_vector([beta])}))


def bands_of(response, edges, transition):
    """The bands of the package's least-squares method: the whole axis, a line across each
    transition band, which is centred on its edge."""
    levels = {"lowpass": [1, 0], "highpass": [0, 1], "bandpass": [0, 1, 0], "bandstop": [1, 0, 1]}[response]
    bands, desired, start = [], [], 0.0
    for index, edge in enumerate(edges):
        lower, upper = edge - transition / 2.0, edge + transition / 2.0
        bands += [start, lower, lower, upper]
        desired += [levels[index], levels[index], levels[index], levels[index + 1]]
        start = upper
    bands += [start, FS / 2.0]
    desired += [levels[-1], levels[-1]]
    return bands, desired, levels


def least_squares(cases):
    for response, edges in EDGES.items():
        bands, desired, levels = bands_of(response, edges, TRANSITION)
        for length in (31, 101, 255):
            for stop_weight in (1.0, 10.0):
                weight = []
                for index in range(len(edges)):
                    weight += [stop_weight if levels[index] == 0 else 1.0, 1.0]
                weight += [stop_weight if levels[-1] == 0 else 1.0]
                taps = signal.firls(numtaps=length, bands=bands, desired=desired, weight=weight, fs=FS)
                cases.append(_golden.case(f"firls-{response}-{length}-w{stop_weight:g}", {
                    "response": response, "edges": edges, "length": length, "transition": TRANSITION,
                    "stopband_weight": stop_weight, "sample_rate": FS, "bands": bands, "desired": desired,
                    "weights": weight}, {"taps": _golden.real_vector(taps)}))

    # The general fit, with part of the axis left out.
    gaps = [
        # name, length, bands (Hz), desired, weights
        ("gap-wide", 31, [0.0, 4000.0, 6000.0, 24000.0], [1.0, 1.0, 0.0, 0.0], [1.0, 1.0]),
        ("gap-weighted", 101, [0.0, 3000.0, 4500.0, 12000.0, 14000.0, 24000.0], [0.0, 0.0, 1.0, 0.5, 0.0, 0.0], [5.0, 1.0, 2.0]),
        # 90 Hz at 48 kHz is the corner of the stress fixture hp-90Hz-48k-order8 (WP-016): a
        # fit that only speaks about 0 … 180 Hz, less than one percent of the axis.
        ("gap-ill-conditioned", 101, [0.0, 45.0, 90.0, 180.0], [0.0, 0.0, 1.0, 1.0], [1.0, 1.0]),
    ]
    for name, length, bands, desired, weight in gaps:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore")      # the ill-conditioned one makes SciPy warn and fall back
            taps = signal.firls(numtaps=length, bands=bands, desired=desired, weight=weight, fs=FS)
        cases.append(_golden.case(f"firls-{name}", {
            "length": length, "sample_rate": FS, "bands": bands, "desired": desired, "weights": weight},
            {"taps": _golden.real_vector(taps)}))


def main():
    cases = []
    windowed_sinc(cases)
    kaiser_estimates(cases)
    least_squares(cases)
    _golden.write(TARGET, "fir_design", cases)


if __name__ == "__main__":
    main()
