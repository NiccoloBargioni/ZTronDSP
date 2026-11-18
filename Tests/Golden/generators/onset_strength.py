"""Golden vectors for the onset strength (WP-525, STG-2).

The table of STG-2 names librosa.onset.onset_strength, "with the same floor and no clipping
relative to the maximum". librosa is not installed where these vectors were generated, so the
reference is written from the published definition with NumPy and SciPy (_rhythm.onset_strength,
which states the librosa call it stands for): the spectral flux of a log-mel spectrogram,

    o[t] = mean over bands of max(0, S[f, t] - R[f, t - lag])

with S the mel power spectrogram of the fixture in decibels, 10·log10(max(p, 1e-16)), its values
raised to the floor, and R either S or S under scipy.ndimage.maximum_filter1d along frequency.
The mel spectrogram is the one of mel.py (_spectral.py): a periodic Hann window, Slaney's formula
and normalisation, 0 Hz to the Nyquist frequency.

    music    frame 2 048, hop 512, 128 bands, the centred frames an offline tool uses
    speech   frame 1 024, hop 256, 64 bands, causal frames: the fixture pauses, and a frame that
             lies inside a pause is silence, which the floor has to hold

Tolerance: 1e-3 of the largest value of the curve.

    python3 onset_strength.py
"""
import _golden
import _fixtures
import _rhythm
import _spectral

numpy, scipy = _golden.oracle()
from scipy import ndimage, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
cases = []

FIXTURES = (
    # name, samples, frame, hop, bands, centred, (lag, max size, floor in dB) …
    ("music", _fixtures.music(numpy), 2048, 512, 128, True, ((1, 1, -80.0), (1, 3, -80.0), (2, 1, 0.0), (3, 5, 10.0), (1, 4, -80.0))),
    ("speech", _fixtures.speech(numpy), 1024, 256, 64, False, ((1, 1, -80.0), (2, 3, -80.0), (1, 1, -20.0))),
)
for name, samples, frame, hop, bands, centred, grid in FIXTURES:
    window = signal.get_window("hann", frame, fftbins=True)
    weights, _ = _spectral.mel_filter_bank(numpy, _fixtures.SAMPLE_RATE, frame, bands, 0.0, _fixtures.SAMPLE_RATE / 2.0, False, True)
    power = numpy.abs(_spectral.stft(numpy, samples, frame, hop, window, frame, centred)) ** 2
    decibels = _rhythm.power_to_decibels(numpy, power @ weights.T)
    for lag, max_size, floor in grid:
        onset = _rhythm.onset_strength(numpy, ndimage, decibels, lag, max_size, floor)
        cases.append(_golden.case(f"{name}-lag{lag}-max{max_size}-floor{int(floor)}", {
            "fixture": name, "frame": frame, "hop": hop, "bands": bands, "centred": 1 if centred else 0,
            "lag": lag, "maxSize": max_size, "floor": floor, "frames": int(onset.shape[0]),
            # How much of the spectrogram lies under the floor: a case where none does says
            # nothing about the floor.
            "flooredShare": float(numpy.mean(decibels < floor)),
            "sampleRate": _fixtures.SAMPLE_RATE},
            {"onset": _golden.real_vector(onset)}))

_golden.write(TARGET, "onset_strength", cases)
