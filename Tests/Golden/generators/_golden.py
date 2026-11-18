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
"""

import json
import os

import _oracle

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


def oracle():
    """Loads the pinned oracles. Returns (numpy, scipy)."""
    return _oracle.load()


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
