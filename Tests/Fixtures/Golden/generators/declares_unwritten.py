"""A generator that declares an output and does not write it."""

import _golden

numpy, scipy = _golden.oracle()

OUTPUTS = ["Tests/CZTronDSPTests/NeverWritten.swift"]

_golden.write("ZTronDSPCoreTests", "declares_unwritten", [])
