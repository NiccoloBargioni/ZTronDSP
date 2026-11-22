"""Writes golden-vector files in the format the loader in ZTronDSPTesting reads (STG-2).

A generator:

    import _golden
    numpy, scipy = _golden.oracle()          # before any other SciPy import
    from scipy import signal

    cases = []
    for order in range(1, 21):
        z, p, k = signal.buttap(order)       # every library argument explicit, no defaults
        cases.append(_golden.case(f"order-{order}", {"order": order},
                                  {"zeros": _golden.complex_vector(z), "poles": _golden.complex_vector(p),
                                   "gain": _golden.real_vector([k])}))
    _golden.write("ZTronDSPDesignTests", "buttap", cases)

    if __name__ == "__main__": main()

The file lands in Tests/<target>/Golden/<generator>.json, inside the test bundle that uses it.
Output is deterministic: sorted keys, floats at `repr` precision, no NaN and no infinity.

A generator whose oracle is librosa gets it from `_golden.librosa()` (never `import librosa`),
writes librosa's output, and holds the NumPy definition it keeps beside it to that output first:

    librosa = _golden.librosa()
    spectrum = librosa.stft(y=x, n_fft=1024, hop_length=256, win_length=1024, window="hann",
                            center=False, dtype=numpy.complex128, pad_mode="constant", out=None)
    _golden.cross_check("stft 1024", spectrum, definition, 1e-12)   # stops the generator if not

The vector file then records librosa's version beside NumPy's and SciPy's.
"""

import json
import os
import sys

import _oracle

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def oracle():
    """Loads the pinned oracles. Returns (numpy, scipy)."""
    return _oracle.load()


def librosa():
    """Loads librosa after the SciPy stand-ins (_oracle.load_librosa) and returns the module.
    Raises ModuleNotFoundError when librosa is not installed: the runner records the generator
    as pending."""
    return _oracle.load_librosa()


def cross_check(what, oracle_values, definition_values, bound):
    """Holds a second, independent computation (the NumPy definition a generator keeps) to the
    oracle's output before anything is written: the largest absolute difference relative to the
    largest absolute value of the oracle's output must not exceed `bound`. Stops the generator
    with both numbers, and the element where they differ most, when it does. Returns the measured
    deviation, which the generator prints."""
    numpy, _ = oracle()
    a = numpy.asarray(oracle_values)
    b = numpy.asarray(definition_values)
    if a.shape != b.shape:
        sys.exit(f"cross-check {what}: the oracle gives shape {a.shape} and the definition {b.shape}")
    if not (numpy.all(numpy.isfinite(a)) and numpy.all(numpy.isfinite(b))):
        sys.exit(f"cross-check {what}: a value is not finite")
    largest = float(numpy.max(numpy.abs(a))) if a.size else 0.0
    difference = numpy.abs(a - b)
    worst = float(numpy.max(difference)) if a.size else 0.0
    deviation = worst / largest if largest > 0 else worst
    if deviation > bound:
        index = numpy.unravel_index(int(numpy.argmax(difference)), a.shape)
        sys.exit(f"cross-check {what}: the definition deviates from the oracle by {deviation:.3e} of the largest value "
                 f"({worst:.6e} of {largest:.6e}); the bound is {bound:.1e}. At {tuple(int(i) for i in index)}: "
                 f"oracle {a[index].item()!r}, definition {b[index].item()!r}")
    print(f"cross-check {what}: {deviation:.2e} of the largest value (bound {bound:.0e})")
    return deviation


def folder(target):
    path = os.path.join(ROOT, "Tests", target, "Golden")
    os.makedirs(path, exist_ok=True)
    return path


def real_vector(values):
    numpy, _ = oracle()
    array = numpy.atleast_1d(numpy.asarray(values, dtype=float)).ravel()
    if not numpy.all(numpy.isfinite(array)):
        raise ValueError("a golden vector holds a non-finite value")
    return [float(v) for v in array]


def complex_vector(values):
    numpy, _ = oracle()
    array = numpy.atleast_1d(numpy.asarray(values, dtype=complex)).ravel()
    if not (numpy.all(numpy.isfinite(array.real)) and numpy.all(numpy.isfinite(array.imag))):
        raise ValueError("a golden vector holds a non-finite value")
    return {"re": [float(v) for v in array.real], "im": [float(v) for v in array.imag]}


def raw_array(target, filename, values, dtype="f32"):
    """Writes a large array as a little-endian raw file beside the JSON and returns its reference.
    `filename` ends in .f32 or .f64 and matches `dtype`."""
    numpy, _ = oracle()
    kind = {"f32": "<f4", "f64": "<f8"}[dtype]
    if not filename.endswith("." + dtype):
        raise ValueError(f"{filename} must end in .{dtype}")
    array = numpy.asarray(values, dtype=float)
    if not numpy.all(numpy.isfinite(array)):
        raise ValueError("a golden array holds a non-finite value")
    with open(os.path.join(folder(target), filename), "wb") as handle:
        handle.write(numpy.ascontiguousarray(array, dtype=kind).tobytes())
    return {"raw": filename, "shape": [int(n) for n in array.shape]}


def case(name, parameters, values):
    """One case: the arguments the oracle was called with (numbers, strings, booleans, lists of
    numbers) and what it returned (real_vector, complex_vector or raw_array values)."""
    return {"name": str(name), "parameters": parameters, "values": values}


def write(target, generator, cases):
    names = [c["name"] for c in cases]
    if len(set(names)) != len(names):
        raise ValueError(f"{generator}: case names must be unique")
    document = {"generator": generator, "oracle": _oracle.versions(), "cases": cases}
    path = os.path.join(folder(target), generator + ".json")
    with open(path, "w") as handle:
        json.dump(document, handle, sort_keys=True, allow_nan=False, separators=(",", ":"))
        handle.write("\n")
    print(f"wrote {os.path.relpath(path, ROOT)} ({len(cases)} cases)")
    return path
