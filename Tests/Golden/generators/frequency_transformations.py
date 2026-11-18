"""Golden vectors for the frequency transformations and the bilinear transform (WP-412…414, STG-2).

Oracle: scipy.signal.lp2lp_zpk, lp2hp_zpk, lp2bp_zpk, lp2bs_zpk, bilinear_zpk; for the
coefficient forms zpk2tf and bilinear.
Grid:   each prototype at orders 2, 5, 8; edges at 0.05, 0.2 and 0.45 of the sample rate;
        bands 0.1 and 1 octave wide, with the listed edge as their upper edge.

Every case carries the oracle's own prototype, so the transformations are tested on their own.
An edge is pre-warped, 2·fs·tan(π·f/fs), which is what makes the bilinear image land on it.

    python3 frequency_transformations.py
"""
import math

import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

FS = 48000.0
ORDERS = (2, 5, 8)
EDGES = (0.05, 0.2, 0.45)
OCTAVES = (0.1, 1.0)


def prototypes(order):
    return {
        "butterworth": signal.buttap(N=order),
        "chebyshev1": signal.cheb1ap(N=order, rp=1.0),
        "chebyshev2": signal.cheb2ap(N=order, rs=60.0),
        "elliptic": signal.ellipap(N=order, rp=1.0, rs=60.0),
        "bessel": signal.besselap(N=order, norm="phase"),
    }


def prewarp(fraction):
    return 2.0 * FS * math.tan(math.pi * fraction)


def vectors(prefix, zpk):
    z, p, k = zpk
    z = numpy.atleast_1d(z)
    return {
        prefix + "zeros": _golden.complex_vector(z) if z.size else {"re": [], "im": []},
        prefix + "poles": _golden.complex_vector(p),
        prefix + "gain": _golden.real_vector([k]),
    }


def transformation(name, parameters, prototype, transformed, order):
    values = {}
    values.update(vectors("prototype_", prototype))
    values.update(vectors("", transformed))
    values.update(vectors("digital_", signal.bilinear_zpk(*transformed, fs=FS)))
    if order <= 5:
        b, a = signal.zpk2tf(*transformed)
        bz, az = signal.bilinear(b, a, fs=FS)
        values["b"] = _golden.real_vector(b)
        values["a"] = _golden.real_vector(a)
        values["digital_b"] = _golden.real_vector(bz)
        values["digital_a"] = _golden.real_vector(az)
    return _golden.case(name, parameters, values)


def main():
    cases = []
    for order in ORDERS:
        for family, (z, p, k) in prototypes(order).items():
            for edge in EDGES:
                wo = prewarp(edge)
                base = {"family": family, "order": order, "sample_rate": FS}
                cases.append(transformation(
                    f"{family}-n{order}-lowpass-{edge}", dict(base, kind="lowpass", wo=wo),
                    (z, p, k), signal.lp2lp_zpk(z, p, k, wo=wo), order))
                cases.append(transformation(
                    f"{family}-n{order}-highpass-{edge}", dict(base, kind="highpass", wo=wo),
                    (z, p, k), signal.lp2hp_zpk(z, p, k, wo=wo), order))
                for octaves in OCTAVES:
                    upper = prewarp(edge)
                    lower = prewarp(edge / 2.0 ** octaves)
                    wo = math.sqrt(lower * upper)
                    bw = upper - lower
                    cases.append(transformation(
                        f"{family}-n{order}-bandpass-{edge}-{octaves}oct", dict(base, kind="bandpass", wo=wo, bw=bw),
                        (z, p, k), signal.lp2bp_zpk(z, p, k, wo=wo, bw=bw), order))
                    cases.append(transformation(
                        f"{family}-n{order}-bandstop-{edge}-{octaves}oct", dict(base, kind="bandstop", wo=wo, bw=bw),
                        (z, p, k), signal.lp2bs_zpk(z, p, k, wo=wo, bw=bw), order))
    _golden.write("ZTronDSPDesignTests", "frequency_transformations", cases)


if __name__ == "__main__":
    main()
