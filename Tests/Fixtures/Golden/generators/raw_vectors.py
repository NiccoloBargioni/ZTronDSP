"""A generator that exercises every value shape: inline real and complex, raw f64 and f32, a matrix."""

import _golden

numpy, scipy = _golden.oracle()

TARGET = "ZTronDSPCoreTests"
n = numpy.arange(8192, dtype=float)
sine = numpy.sin(2 * numpy.pi * 440.0 * n / 48000.0)
matrix = numpy.arange(12, dtype=float).reshape(3, 4) / 7.0
spectrum = numpy.fft.rfft(a=sine, n=8192, axis=-1, norm="backward")

cases = [_golden.case("shapes", {"sampleRate": 48000.0, "frequency": 440.0, "label": "sine"}, {
    "short": _golden.real_vector([1.0, 0.5, 0.25]),
    "pair": _golden.complex_vector([1 + 2j, 3 - 4j]),
    "long": _golden.raw_array(TARGET, "raw_vectors.long.f64", sine, dtype="f64"),
    "long32": _golden.raw_array(TARGET, "raw_vectors.long32.f32", sine, dtype="f32"),
    "matrix": _golden.raw_array(TARGET, "raw_vectors.matrix.f64", matrix, dtype="f64"),
    "spectrum_re": _golden.raw_array(TARGET, "raw_vectors.spectrum_re.f64", spectrum.real, dtype="f64"),
    "spectrum_im": _golden.raw_array(TARGET, "raw_vectors.spectrum_im.f64", spectrum.imag, dtype="f64"),
})]
_golden.write(TARGET, "raw_vectors", cases)
