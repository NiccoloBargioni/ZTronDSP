"""Golden vectors for the order estimates (WP-415…417, WP-418c, STG-2).

Oracle: scipy.signal.buttord, cheb1ord, cheb2ord, ellipord, and scipy.signal.iirfilter for the
filter that results from each estimate.
Grid:   three tolerance schemes per response, each in the digital domain (hertz at 48 kHz) and
        in the analog domain (the same numbers times 2π, in rad/s).

    python3 iir_order.py
"""
import math

import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

FS = 48000.0

# (pass-band edges, stop-band edges, maximum loss in dB, minimum attenuation in dB), in hertz.
SCHEMES = {
    "lowpass": [(1000.0, 2000.0, 1.0, 40.0), (4000.0, 6000.0, 0.5, 60.0), (200.0, 1500.0, 3.0, 30.0)],
    "highpass": [(2000.0, 1000.0, 1.0, 40.0), (6000.0, 4000.0, 0.5, 60.0), (1500.0, 200.0, 3.0, 30.0)],
    "bandpass": [((1000.0, 2000.0), (500.0, 3000.0), 1.0, 40.0),
                 ((3000.0, 3400.0), (2600.0, 4000.0), 0.5, 60.0),
                 ((300.0, 3400.0), (100.0, 6000.0), 3.0, 30.0)],
    "bandstop": [((500.0, 3000.0), (1000.0, 2000.0), 1.0, 40.0),
                 ((2600.0, 4000.0), (3000.0, 3400.0), 0.5, 60.0),
                 ((100.0, 6000.0), (300.0, 3400.0), 3.0, 30.0)],
}

ESTIMATORS = {
    "butterworth": (signal.buttord, "butter"),
    "chebyshev1": (signal.cheb1ord, "cheby1"),
    "chebyshev2": (signal.cheb2ord, "cheby2"),
    "elliptic": (signal.ellipord, "ellip"),
}


def scaled(edges, factor):
    if isinstance(edges, tuple):
        return [e * factor for e in edges]
    return edges * factor


def main():
    cases = []
    for family, (estimate, ftype) in ESTIMATORS.items():
        for response, schemes in SCHEMES.items():
            for index, (passband, stopband, loss, attenuation) in enumerate(schemes):
                for analog in (False, True):
                    factor = 2.0 * math.pi if analog else 1.0
                    wp = scaled(passband, factor)
                    ws = scaled(stopband, factor)
                    fs = None if analog else FS
                    order, natural = estimate(wp=wp, ws=ws, gpass=loss, gstop=attenuation, analog=analog, fs=fs)
                    z, p, k = signal.iirfilter(N=order, Wn=natural, rp=loss, rs=attenuation, btype=response,
                                               analog=analog, ftype=ftype, output="zpk", fs=fs)
                    z = numpy.atleast_1d(z)
                    domain = "analog" if analog else "digital"
                    parameters = {
                        "family": family, "response": response, "domain": domain,
                        "passband": wp, "stopband": ws, "maximum_loss": loss, "minimum_attenuation": attenuation,
                        "order": int(order),
                    }
                    if not analog:
                        parameters["sample_rate"] = FS
                    cases.append(_golden.case(f"{family}-{response}-{index}-{domain}", parameters, {
                        "natural": _golden.real_vector(natural),
                        "zeros": _golden.complex_vector(z) if z.size else {"re": [], "im": []},
                        "poles": _golden.complex_vector(p),
                        "gain": _golden.real_vector([k]),
                    }))
    _golden.write("ZTronDSPDesignTests", "iir_order", cases)


if __name__ == "__main__":
    main()
