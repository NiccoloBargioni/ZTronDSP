"""Golden vectors for the peaking section and the shelves (WP-420, STG-2).

Oracle: the formulas of R. Bristow-Johnson's Audio EQ Cookbook, evaluated in double precision.
Grid:   gains ±6 and ±12 dB; Q 0.5, 1, 4; centres 100 Hz, 1 kHz, 10 kHz; shelves also with the
        slope form, S = 0.5 and 1. Sample rate 48 kHz.
A section is stored normalised by a0: b0 b1 b2 a1 a2.

    python3 cookbook_equalizers.py
"""
import math

import _golden

numpy, scipy = _golden.oracle()

FS = 48000.0
GAINS = (6.0, -6.0, 12.0, -12.0)
QUALITIES = (0.5, 1.0, 4.0)
SLOPES = (0.5, 1.0)
CENTRES = (100.0, 1000.0, 10000.0)


def normalised(b0, b1, b2, a0, a1, a2):
    return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]


def peaking(f0, gain, q):
    amplitude = 10.0 ** (gain / 40.0)
    w0 = 2.0 * math.pi * f0 / FS
    alpha = math.sin(w0) / (2.0 * q)
    return normalised(1.0 + alpha * amplitude, -2.0 * math.cos(w0), 1.0 - alpha * amplitude,
                      1.0 + alpha / amplitude, -2.0 * math.cos(w0), 1.0 - alpha / amplitude)


def shelf_alpha(w0, amplitude, q=None, slope=None):
    if q is not None:
        return math.sin(w0) / (2.0 * q)
    return math.sin(w0) / 2.0 * math.sqrt((amplitude + 1.0 / amplitude) * (1.0 / slope - 1.0) + 2.0)


def low_shelf(f0, gain, q=None, slope=None):
    amplitude = 10.0 ** (gain / 40.0)
    w0 = 2.0 * math.pi * f0 / FS
    cosine = math.cos(w0)
    edge = 2.0 * math.sqrt(amplitude) * shelf_alpha(w0, amplitude, q, slope)
    return normalised(
        amplitude * ((amplitude + 1.0) - (amplitude - 1.0) * cosine + edge),
        2.0 * amplitude * ((amplitude - 1.0) - (amplitude + 1.0) * cosine),
        amplitude * ((amplitude + 1.0) - (amplitude - 1.0) * cosine - edge),
        (amplitude + 1.0) + (amplitude - 1.0) * cosine + edge,
        -2.0 * ((amplitude - 1.0) + (amplitude + 1.0) * cosine),
        (amplitude + 1.0) + (amplitude - 1.0) * cosine - edge)


def high_shelf(f0, gain, q=None, slope=None):
    amplitude = 10.0 ** (gain / 40.0)
    w0 = 2.0 * math.pi * f0 / FS
    cosine = math.cos(w0)
    edge = 2.0 * math.sqrt(amplitude) * shelf_alpha(w0, amplitude, q, slope)
    return normalised(
        amplitude * ((amplitude + 1.0) + (amplitude - 1.0) * cosine + edge),
        -2.0 * amplitude * ((amplitude - 1.0) + (amplitude + 1.0) * cosine),
        amplitude * ((amplitude + 1.0) + (amplitude - 1.0) * cosine - edge),
        (amplitude + 1.0) - (amplitude - 1.0) * cosine + edge,
        2.0 * ((amplitude - 1.0) - (amplitude + 1.0) * cosine),
        (amplitude + 1.0) - (amplitude - 1.0) * cosine - edge)


def main():
    cases = []
    for f0 in CENTRES:
        for gain in GAINS:
            base = {"frequency": f0, "gain": gain, "sample_rate": FS}
            for q in QUALITIES:
                cases.append(_golden.case(f"peaking-{f0}-{gain}-q{q}", dict(base, kind="peaking", q=q),
                                          {"section": _golden.real_vector(peaking(f0, gain, q))}))
                cases.append(_golden.case(f"lowshelf-{f0}-{gain}-q{q}", dict(base, kind="lowshelf", q=q),
                                          {"section": _golden.real_vector(low_shelf(f0, gain, q=q))}))
                cases.append(_golden.case(f"highshelf-{f0}-{gain}-q{q}", dict(base, kind="highshelf", q=q),
                                          {"section": _golden.real_vector(high_shelf(f0, gain, q=q))}))
            for slope in SLOPES:
                cases.append(_golden.case(f"lowshelf-{f0}-{gain}-s{slope}", dict(base, kind="lowshelf", slope=slope),
                                          {"section": _golden.real_vector(low_shelf(f0, gain, slope=slope))}))
                cases.append(_golden.case(f"highshelf-{f0}-{gain}-s{slope}", dict(base, kind="highshelf", slope=slope),
                                          {"section": _golden.real_vector(high_shelf(f0, gain, slope=slope))}))
    _golden.write("ZTronDSPDesignTests", "cookbook_equalizers", cases)


if __name__ == "__main__":
    main()
