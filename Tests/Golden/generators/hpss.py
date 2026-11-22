"""Golden vectors for the masks of the harmonic–percussive separation (WP-530, WP-531a, WP-531b;
STG-2): the reference of the acceptance of §6.10.

Oracle: librosa 0.11.0, ORACLE FORM. What is written is librosa's masks, every argument
explicit, the input in float64:

    S = numpy.abs(librosa.stft(y=x, n_fft=1024, hop_length=hop, win_length=1024, window="hann",
                               center=True, dtype=numpy.complex128, pad_mode="reflect", out=None))
        of which the frames a stream has (spectral_transforms.py), bins × frames
    librosa.decompose.hpss(S, kernel_size=(time kernel, frequency kernel), power=p, mask=True,
                           margin=(harmonic margin, percussive margin))

p is the soft mask's power, or numpy.inf for the hard mask. librosa takes the medians by
scipy.ndimage.median_filter with reflected edges, over the spectrogram it is given: the frames of
the stream, both edges reflected, which is what the offline separation of the package computes
for the same frames.

One rule is the specification's and not librosa's: where the larger of a mask's two values lies
below the floor (1e-10), both masks are 0 (librosa uses the smallest normal number there, and
shares such a bin equally when the margins are 1). It changes nothing here: the generator asserts
that no bin of these spectrograms lies under the floor (the smallest larger value is about 0.006)
and stops otherwise, so librosa's masks are the specification's.

Cross-check, before anything is written, within 1e-12 (double precision): the definition of
_separation.py (Fitzgerald 2010) on the spectrogram of _spectral.py, M_H = H^p / (H^p + (m_H·P)^p),
M_P = P^p / (P^p + (m_P·H)^p), or their hard limit.

Read by ZTronDSPAnalysisTests (SeparationMaskTests). Tolerances (§6.10): soft masks within 1e-3
on bins above −60 dB of the frame maximum; hard masks equal on at least 99.9 % of those bins.

    python3 hpss.py
"""
import _golden
import _fixtures
import _separation
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
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
    samples = fixtures[fixture]
    count = (len(samples) - FRAME // 2) // hop + 1
    spectrogram = numpy.abs(librosa.stft(y=numpy.asarray(samples, dtype=numpy.float64), n_fft=FRAME, hop_length=hop, win_length=FRAME,
                                         window="hann", center=True, dtype=numpy.complex128, pad_mode="reflect", out=None))[:, :count]
    harmonic_mask, percussive_mask = librosa.decompose.hpss(spectrogram, kernel_size=(time_kernel, frequency_kernel),
                                                            power=numpy.inf if power is None else power, mask=True,
                                                            margin=(harmonic_margin, percussive_margin))
    harmonic_mask = numpy.asarray(harmonic_mask, dtype=numpy.float64).T
    percussive_mask = numpy.asarray(percussive_mask, dtype=numpy.float64).T

    magnitudes = numpy.abs(_spectral.stft(numpy, samples, FRAME, hop, window, FRAME, True))
    harmonic, percussive = _separation.medians(ndimage, magnitudes, time_kernel, frequency_kernel)
    smallest = min(float(numpy.min(numpy.maximum(harmonic, percussive * harmonic_margin))),
                   float(numpy.min(numpy.maximum(percussive, harmonic * percussive_margin))))
    if smallest < FLOOR:
        raise SystemExit(f"hpss {name}: a bin lies under the floor ({smallest:.3e} < {FLOOR:.0e}): librosa's masks are not the specification's there")
    definition = _separation.masks(numpy, harmonic, percussive, power, harmonic_margin, percussive_margin, FLOOR)
    _golden.cross_check(f"hpss {name} harmonic", harmonic_mask, definition[0], 1e-12)
    _golden.cross_check(f"hpss {name} percussive", percussive_mask, definition[1], 1e-12)
    print(f"hpss {name}: the smallest larger value of a mask's two is {smallest:.3e} (floor {FLOOR:.0e})")
    cases.append(_golden.case(name, {
        "fixture": fixture, "frame": FRAME, "hop": hop, "timeKernel": time_kernel, "frequencyKernel": frequency_kernel,
        "hard": 1 if power is None else 0, "power": 0.0 if power is None else power,
        "harmonicMargin": harmonic_margin, "percussiveMargin": percussive_margin, "floor": FLOOR,
        "frames": int(harmonic_mask.shape[0]), "bins": int(harmonic_mask.shape[1]), "sampleRate": _fixtures.SAMPLE_RATE},
        {"harmonic": _golden.raw_array(TARGET, f"hpss_{name}_harmonic.f32", harmonic_mask, dtype="f32"),
         "percussive": _golden.raw_array(TARGET, f"hpss_{name}_percussive.f32", percussive_mask, dtype="f32")}))

_golden.write(TARGET, "hpss", cases)
