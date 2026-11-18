"""Golden vectors for the masks of the harmonic–percussive separation (WP-530, WP-531a, WP-531b;
STG-2): the reference of the acceptance of §6.10.

The table of STG-2 names librosa for this. librosa is not installed where these vectors were
generated, so the reference is written from the published definition with NumPy and SciPy
(_separation.py, which states the librosa calls it stands for): the medians of the magnitude
spectrogram along time and along frequency by scipy.ndimage.median_filter with reflected edges,
and the masks M_H = H^p / (H^p + (m_H·P)^p), M_P = P^p / (P^p + (m_P·H)^p), or their hard limit.
One difference from librosa is the specification's: where neither median reaches the floor both
masks are 0 (librosa shares such a bin equally when the margins are 1).

The spectrogram is the magnitude of the STFT of the fixture (_spectral.py): a periodic Hann
window of 1 024 samples, a hop of 256 (music: 512), the centred frames a stream produces. The
medians are centred, with both edges of the spectrogram reflected: what the offline separation
of the package computes for the same frames.

Tolerances (§6.10): soft masks within 1e-3 on bins above -60 dB of the frame maximum; hard masks
equal on at least 99.9 % of those bins.

    python3 hpss.py
"""
import _golden
import _fixtures
import _separation
import _spectral

numpy, scipy = _golden.oracle()
from scipy import ndimage, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
FRAME = 1024
FLOOR = 1e-10
cases = []

CASES = (
    # name, fixture, hop, time kernel, frequency kernel, power (None: hard), harmonic margin, percussive margin
    ("music-soft2-31-31", "music", 512, 31, 31, 2.0, 1.0, 1.0),
    ("music-hard-31-31", "music", 512, 31, 31, None, 1.0, 1.0),
    ("music-soft1-17-17-margins", "music", 512, 17, 17, 1.0, 2.0, 3.0),
    ("speech-soft2-17-31", "speech", 256, 17, 31, 2.0, 1.0, 1.0),
)
window = signal.get_window("hann", FRAME, fftbins=True)
fixtures = {"music": _fixtures.music(numpy), "speech": _fixtures.speech(numpy)}
for name, fixture, hop, time_kernel, frequency_kernel, power, harmonic_margin, percussive_margin in CASES:
    magnitudes = numpy.abs(_spectral.stft(numpy, fixtures[fixture], FRAME, hop, window, FRAME, True))
    harmonic, percussive = _separation.medians(ndimage, magnitudes, time_kernel, frequency_kernel)
    harmonic_mask, percussive_mask = _separation.masks(numpy, harmonic, percussive, power, harmonic_margin, percussive_margin, FLOOR)
    cases.append(_golden.case(name, {
        "fixture": fixture, "frame": FRAME, "hop": hop, "timeKernel": time_kernel, "frequencyKernel": frequency_kernel,
        "hard": 1 if power is None else 0, "power": 0.0 if power is None else power,
        "harmonicMargin": harmonic_margin, "percussiveMargin": percussive_margin, "floor": FLOOR,
        "frames": int(magnitudes.shape[0]), "bins": int(magnitudes.shape[1]), "sampleRate": _fixtures.SAMPLE_RATE},
        {"harmonic": _golden.raw_array(TARGET, f"hpss_{name}_harmonic.f32", harmonic_mask, dtype="f32"),
         "percussive": _golden.raw_array(TARGET, f"hpss_{name}_percussive.f32", percussive_mask, dtype="f32")}))

_golden.write(TARGET, "hpss", cases)
