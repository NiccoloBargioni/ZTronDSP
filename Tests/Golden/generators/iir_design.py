"""Golden vectors for IIR design and for the response analysis (WP-418a, WP-418b, WP-429, WP-430, STG-2).

Oracle: scipy.signal.iirfilter for the designs; freqs, sosfreqz and group_delay for the analysis.
Grid:   family × response × orders 1, 2, 5, 8, in the analog and in the digital domain;
        512 frequencies.

Analog designs are analysed with freqs on the coefficients iirfilter returns, as the table of
STG-2 says. On this grid that is accurate: it agrees with the zero-pole evaluation (freqs_zpk)
to 3.3e-11 of the peak, the worst case being the order-8 elliptic band-pass.

Digital designs are analysed in the factored form: sosfreqz, and group_delay section by section
with the delays added. Applied to the expanded coefficients the digital oracles lose their
digits and the vectors would be wrong before any test ran: freqz(b, a) differs from sosfreqz
by 4e-2 of the peak for the order-8 elliptic band-pass, and group_delay((b, a)) is off by
1.3e-3 samples beside the notch of the order-2 band-stops. For orders 1 and 2 the coefficient
form is evaluated as a whole as well, by freqz and group_delay, for the analysis of a system
given as coefficients.

Layout. The designs are JSON cases. The sampled curves are three raw Float64 matrices beside the
JSON, one row block per design; a design names its block with the parameters `row` and `tf_row`:

    iir_design_analog.f64      [designs, 2, 512]   Re H, Im H (freqs)
    iir_design_digital.f64     [designs, 4, 512]   Re H, Im H, group delay, unwrapped phase
    iir_design_digital_tf.f64  [designs of order ≤ 2, 3, 512]   Re H, Im H, group delay of the coefficient form

    python3 iir_design.py
"""
import math
import warnings

import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPDesignTests"
FS = 48000.0
ORDERS = (1, 2, 5, 8)
POINTS = 512

# name -> (ftype, pass-band ripple, stop-band attenuation)
FAMILIES = {
    "butterworth": ("butter", None, None),
    "chebyshev1": ("cheby1", 1.0, None),
    "chebyshev2": ("cheby2", None, 60.0),
    "elliptic": ("ellip", 1.0, 60.0),
    "bessel": ("bessel_phase", None, None),
}

DIGITAL_EDGES = {"lowpass": 3000.0, "highpass": 3000.0, "bandpass": [2000.0, 5000.0], "bandstop": [2000.0, 5000.0]}
ANALOG_EDGES = {
    "lowpass": 2.0 * math.pi * 1000.0, "highpass": 2.0 * math.pi * 1000.0,
    "bandpass": [2.0 * math.pi * 1000.0, 2.0 * math.pi * 3000.0],
    "bandstop": [2.0 * math.pi * 1000.0, 2.0 * math.pi * 3000.0],
}

DIGITAL_W = numpy.linspace(0.0, numpy.pi, POINTS, endpoint=False)
ANALOG_W = numpy.logspace(math.log10(2.0 * math.pi * 10.0), math.log10(2.0 * math.pi * 100000.0), POINTS,
                          endpoint=True, base=10.0)


def complex_or_empty(values):
    values = numpy.atleast_1d(values)
    return _golden.complex_vector(values) if values.size else {"re": [], "im": []}


def design(family, response, order, analog, curves, tf_curves):
    ftype, ripple, attenuation = FAMILIES[family]
    edges = ANALOG_EDGES[response] if analog else DIGITAL_EDGES[response]
    fs = None if analog else FS
    common = dict(N=order, Wn=edges, rp=ripple, rs=attenuation, btype=response, analog=analog, ftype=ftype, fs=fs)
    z, p, k = signal.iirfilter(output="zpk", **common)
    b, a = signal.iirfilter(output="ba", **common)
    parameters = {"family": family, "response": response, "order": order,
                  "domain": "analog" if analog else "digital", "edges": edges, "row": len(curves)}
    if ripple is not None:
        parameters["ripple"] = ripple
    if attenuation is not None:
        parameters["stopband"] = attenuation
    values = {
        "zeros": complex_or_empty(z), "poles": _golden.complex_vector(p), "gain": _golden.real_vector([k]),
        "b": _golden.real_vector(b), "a": _golden.real_vector(a),
    }

    if analog:
        _, h = signal.freqs(b, a, worN=ANALOG_W, plot=None)
        curves.append([h.real, h.imag])
    else:
        parameters["sample_rate"] = FS
        sections = signal.iirfilter(output="sos", **common)
        values["sos"] = _golden.real_vector(sections)
        _, h = signal.sosfreqz(sections, worN=DIGITAL_W, whole=False, fs=2.0 * numpy.pi)
        delay = numpy.zeros(POINTS)
        with warnings.catch_warnings():
            # A zero on the unit circle at a grid point makes the delay singular there; SciPy
            # warns and writes 0. Those points are the ones the package reports as undefined.
            warnings.simplefilter("ignore")
            for row in sections:
                _, part = signal.group_delay((row[:3], row[3:]), w=DIGITAL_W, whole=False, fs=2.0 * numpy.pi)
                delay = delay + part
            if order <= 2:
                _, whole_delay = signal.group_delay((b, a), w=DIGITAL_W, whole=False, fs=2.0 * numpy.pi)
        phase = numpy.unwrap(numpy.angle(h, deg=False), discont=None, axis=-1, period=2.0 * numpy.pi)
        curves.append([h.real, h.imag, delay, phase])
        if order <= 2:
            _, whole = signal.freqz(b, a, worN=DIGITAL_W, whole=False, plot=None, fs=2.0 * numpy.pi,
                                    include_nyquist=False)
            parameters["tf_row"] = len(tf_curves)
            tf_curves.append([whole.real, whole.imag, whole_delay])
    name = f"{family}-{response}-n{order}-{'analog' if analog else 'digital'}"
    return _golden.case(name, parameters, values)


def main():
    cases = [_golden.case("grid", {"points": POINTS}, {
        "analog": _golden.real_vector(ANALOG_W), "digital": _golden.real_vector(DIGITAL_W)})]
    for analog in (True, False):
        curves, tf_curves = [], []
        for family in FAMILIES:
            for response in DIGITAL_EDGES:
                for order in ORDERS:
                    cases.append(design(family, response, order, analog, curves, tf_curves))
        domain = "analog" if analog else "digital"
        values = {"curves": _golden.raw_array(TARGET, f"iir_design_{domain}.f64", numpy.asarray(curves), dtype="f64")}
        if tf_curves:
            values["tf_curves"] = _golden.raw_array(TARGET, f"iir_design_{domain}_tf.f64", numpy.asarray(tf_curves), dtype="f64")
        cases.append(_golden.case(f"{domain}-curves", {"domain": domain}, values))
    _golden.write(TARGET, "iir_design", cases)


if __name__ == "__main__":
    main()
