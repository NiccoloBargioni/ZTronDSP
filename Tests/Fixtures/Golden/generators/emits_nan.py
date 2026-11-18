"""A generator that produces a NaN: the vector must be refused, not written."""

import _golden

numpy, scipy = _golden.oracle()

with numpy.errstate(invalid="ignore"):
    values = numpy.array([0.0]) / numpy.array([0.0])

_golden.write("ZTronDSPCoreTests", "emits_nan", [_golden.case("zero-over-zero", {"x": 0}, {"y": _golden.real_vector(values)})])
