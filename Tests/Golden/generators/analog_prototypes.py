"""Golden vectors for the analog low-pass prototypes (WP-405…411, STG-2).

Oracle: scipy.signal.buttap, cheb1ap, cheb2ap, ellipap, besselap.
Grid:   orders 1…12 (Butterworth to 20, Bessel to 25); ripple 0.1, 1, 3 dB;
        attenuation 40, 60, 80 dB; the three Bessel normalisations.

    python3 analog_prototypes.py
"""
import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

RIPPLES = (0.1, 1.0, 3.0)
ATTENUATIONS = (40.0, 60.0, 80.0)


def prototype(name, parameters, zpk):
    z, p, k = zpk
    return _golden.case(name, parameters, {
        "zeros": _golden.complex_vector(z),
        "poles": _golden.complex_vector(p),
        "gain": _golden.real_vector([k]),
    })


def main():
    cases = []
    for order in range(1, 21):
        cases.append(prototype(f"butterworth-n{order}", {"family": "butterworth", "order": order},
                               signal.buttap(N=order)))
    for order in range(1, 13):
        for ripple in RIPPLES:
            cases.append(prototype(f"chebyshev1-n{order}-rp{ripple}",
                                   {"family": "chebyshev1", "order": order, "ripple": ripple},
                                   signal.cheb1ap(N=order, rp=ripple)))
        for attenuation in ATTENUATIONS:
            cases.append(prototype(f"chebyshev2-n{order}-rs{attenuation}",
                                   {"family": "chebyshev2", "order": order, "stopband": attenuation},
                                   signal.cheb2ap(N=order, rs=attenuation)))
        for ripple in RIPPLES:
            for attenuation in ATTENUATIONS:
                cases.append(prototype(f"elliptic-n{order}-rp{ripple}-rs{attenuation}",
                                       {"family": "elliptic", "order": order, "ripple": ripple, "stopband": attenuation},
                                       signal.ellipap(N=order, rp=ripple, rs=attenuation)))
    for order in range(1, 26):
        for norm in ("phase", "delay", "mag"):
            cases.append(prototype(f"bessel-n{order}-{norm}",
                                   {"family": "bessel", "order": order, "normalization": norm},
                                   signal.besselap(N=order, norm=norm)))
    _golden.write("ZTronDSPDesignTests", "analog_prototypes", cases)


if __name__ == "__main__":
    main()
