"""One script that writes two vector files: both belong to it in the manifest."""

import _golden

numpy, scipy = _golden.oracle()

for suffix, scale in (("a", 1.0), ("b", 2.0)):
    _golden.write("ZTronDSPCoreTests", "two_documents_" + suffix,
                  [_golden.case("ramp", {"scale": scale}, {"y": _golden.real_vector(scale * numpy.arange(4, dtype=float))})])
