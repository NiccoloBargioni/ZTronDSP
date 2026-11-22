"""A generator whose second computation deviates from the oracle by more than the bound: the
cross-check stops it before anything is written, with both numbers."""

import _golden

numpy, scipy = _golden.oracle()

oracle = numpy.array([1.0, -2.0, 3.0])
_golden.cross_check("a definition one part in 1e9 away", oracle, oracle * (1.0 + 1e-9), 1e-12)
_golden.write("ZTronDSPAnalysisTests", "cross_check_fails",
              [_golden.case("never", {}, {"values": _golden.real_vector(oracle)})])
