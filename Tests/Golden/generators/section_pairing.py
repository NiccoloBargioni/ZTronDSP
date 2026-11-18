"""Golden vectors for the pairing of zeros and poles into second-order sections (WP-404, STG-2).

Oracle: scipy.signal.zpk2sos(pairing='nearest', analog=False), fed with digital designs of
scipy.signal.iirfilter and with hand-made systems that exercise the padding rules.
A section is stored as SciPy returns it: b0 b1 b2 a0 a1 a2, with a0 = 1.

    python3 section_pairing.py
"""
import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

FS = 48000.0

DESIGNS = [
    # ftype, order, btype, edges (Hz), rp, rs
    ("butter", 1, "lowpass", 3000.0, None, None),
    ("butter", 2, "highpass", 3000.0, None, None),
    ("butter", 3, "lowpass", 900.0, None, None),
    ("butter", 6, "lowpass", 3000.0, None, None),
    ("butter", 7, "highpass", 7000.0, None, None),
    ("butter", 4, "bandpass", (2000.0, 5000.0), None, None),
    ("butter", 3, "bandstop", (2000.0, 5000.0), None, None),
    ("butter", 16, "lowpass", 1000.0, None, None),
    ("cheby1", 4, "lowpass", 3000.0, 1.0, None),
    ("cheby1", 5, "bandpass", (2000.0, 5000.0), 1.0, None),
    ("cheby2", 4, "lowpass", 3000.0, None, 60.0),
    ("cheby2", 5, "highpass", 3000.0, None, 60.0),
    ("cheby2", 7, "bandstop", (2000.0, 5000.0), None, 60.0),
    ("ellip", 3, "lowpass", 3000.0, 1.0, 60.0),
    ("ellip", 6, "bandpass", (2000.0, 5000.0), 1.0, 60.0),
    ("ellip", 9, "highpass", 12000.0, 0.1, 80.0),
    ("ellip", 5, "bandstop", (2000.0, 5000.0), 3.0, 40.0),
    ("bessel", 5, "lowpass", 3000.0, None, None),
    ("bessel", 4, "bandpass", (2000.0, 5000.0), None, None),
]

HAND_MADE = [
    ("more-zeros-than-poles", [-1.0, -1.0, 0.5 + 0.5j, 0.5 - 0.5j], [0.9, 0.2 + 0.3j, 0.2 - 0.3j], 2.0),
    ("real-poles-only", [1.0, -1.0], [0.9, 0.8, -0.7, 0.1], -0.5),
    ("no-zeros", [], [0.5 + 0.5j, 0.5 - 0.5j, 0.3], 1.0),
    ("zeros-only", [0.9 + 0.1j, 0.9 - 0.1j, -0.5], [], 0.25),
    ("gain-only", [], [], 3.0),
    ("repeated-roots", [-1.0, -1.0, -1.0, -1.0], [0.5, 0.5, 0.6 + 0.2j, 0.6 - 0.2j], 0.01),
    ("one-pole", [], [0.95], 0.05),
    ("mixed-real-zeros", [0.3, -0.8, 0.99 + 0.1j, 0.99 - 0.1j], [0.7 + 0.6j, 0.7 - 0.6j, -0.2 + 0.1j, -0.2 - 0.1j], 1.5),
]


def pairing(name, parameters, z, p, k):
    z = numpy.asarray(z, dtype=complex)
    p = numpy.asarray(p, dtype=complex)
    sos = signal.zpk2sos(z, p, k, pairing="nearest", analog=False)
    parameters = dict(parameters, sections=int(sos.shape[0]))
    return _golden.case(name, parameters, {
        "zeros": _golden.complex_vector(z) if z.size else {"re": [], "im": []},
        "poles": _golden.complex_vector(p) if p.size else {"re": [], "im": []},
        "gain": _golden.real_vector([k]),
        "sos": _golden.real_vector(sos),
    })


def main():
    cases = []
    for ftype, order, btype, edges, rp, rs in DESIGNS:
        z, p, k = signal.iirfilter(N=order, Wn=edges, rp=rp, rs=rs, btype=btype, analog=False, ftype=ftype,
                                   output="zpk", fs=FS)
        name = f"{ftype}-n{order}-{btype}"
        cases.append(pairing(name, {"family": ftype, "order": order, "response": btype}, z, p, float(k)))
    for name, z, p, k in HAND_MADE:
        cases.append(pairing(name, {"family": "hand-made"}, z, p, k))
    _golden.write("ZTronDSPDesignTests", "section_pairing", cases)


if __name__ == "__main__":
    main()
