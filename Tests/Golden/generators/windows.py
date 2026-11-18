"""The package's own windows (WP-501b) against scipy.signal.windows.

Oracle: scipy.signal.windows.blackmanharris, kaiser, flattop, gaussian, boxcar, each in the
periodic (sym=False) and the symmetric (sym=True) form. The package states the standard
deviation of a Gaussian window as a fraction of the frame, so the oracle is called with
std = sigma * D, D being the frame length for the periodic form and one less for the symmetric.
"""
import _golden

numpy, scipy = _golden.oracle()
from scipy import signal

cases = []
for count in (2, 5, 16, 63, 64, 1024):
    for symmetric in (False, True):
        span = count - 1 if symmetric else count
        shapes = [
            ("rectangular", {}, signal.windows.boxcar(M=count, sym=symmetric)),
            ("blackmanHarris", {}, signal.windows.blackmanharris(M=count, sym=symmetric)),
            ("flatTop", {}, signal.windows.flattop(M=count, sym=symmetric)),
        ]
        for beta in (0.0, 2.5, 8.6, 14.0):
            shapes.append(("kaiser", {"beta": beta}, signal.windows.kaiser(M=count, beta=beta, sym=symmetric)))
        for sigma in (0.1, 0.25, 0.4):
            shapes.append(("gaussian", {"sigma": sigma}, signal.windows.gaussian(M=count, std=sigma * span, sym=symmetric)))
        for name, parameters, values in shapes:
            label = "-".join([name] + [f"{key}{value}" for key, value in parameters.items()]
                             + [str(count), "symmetric" if symmetric else "periodic"])
            cases.append(_golden.case(label, {"window": name, "count": count, "symmetric": 1 if symmetric else 0, **parameters},
                                      {"samples": _golden.real_vector(values)}))

_golden.write("ZTronDSPCoreTests", "windows", cases)
