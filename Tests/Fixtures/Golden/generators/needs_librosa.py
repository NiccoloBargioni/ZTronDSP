"""A generator whose oracle is librosa, loaded through _golden.librosa() (never `import librosa`).

With the pinned librosa installed it writes one value of librosa's, held first to its NumPy
definition by _golden.cross_check, and its vector file records librosa's version beside NumPy's
and SciPy's. Without librosa it stops on Python's own "No module named 'librosa'", and the runner
records it as pending (or keeps its committed vectors)."""

import _golden

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()

hertz = numpy.array([0.0, 440.0, 1000.0, 8000.0], dtype=numpy.float64)
mel = librosa.hz_to_mel(frequencies=hertz, htk=True)
_golden.cross_check("hz_to_mel, htk", mel, 2595.0 * numpy.log10(1.0 + hertz / 700.0), 1e-12)
_golden.write("ZTronDSPAnalysisTests", "needs_librosa",
              [_golden.case("htk", {"hertz": [float(h) for h in hertz], "htk": True}, {"mel": _golden.real_vector(mel)})])
