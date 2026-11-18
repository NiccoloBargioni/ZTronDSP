"""Golden vectors for the mel scale (WP-508, WP-535, STG-2).

The table of STG-2 names librosa for the mel filter bank. librosa is not installed where these
vectors were generated, so the references are written from the published definitions with
NumPy only (_spectral.py): the two hertz ↔ mel formulas (librosa.hz_to_mel / mel_to_hz, Slaney
and HTK), the triangular filter bank (librosa.filters.mel, norm="slaney" or None), and the mel
power spectrogram of the fixtures, weights @ |STFT|², with the centred framing an offline tool
uses (librosa.feature.melspectrogram with center=True, power=2.0, a periodic Hann window).

Tolerances: conversions 1e-9 relative; weights 1e-6; the mel power spectrogram 1e-4 of the
frame maximum.

    python3 mel.py
"""
import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
cases = []

# --- The formulas ------------------------------------------------------------------------------------
hertz = numpy.array([0.0, 1.0, 50.0, 200.0, 440.0, 999.9, 1000.0, 1000.1, 2500.0, 4000.0, 8000.0, 11025.0, 16000.0, 24000.0])
cases.append(_golden.case("formulas", {}, {
    "hertz": _golden.real_vector(hertz),
    "slaney": _golden.real_vector(_spectral.hz_to_mel(numpy, hertz, False)),
    "htk": _golden.real_vector(_spectral.hz_to_mel(numpy, hertz, True))}))

# --- The filter bank ---------------------------------------------------------------------------------
BANKS = (
    # name, sample rate, transform length, bands, fmin, fmax, htk, Slaney normalisation
    ("default-22050-2048-128", 22050.0, 2048, 128, 0.0, 11025.0, False, True),
    ("htk-48000-1024-40-peak", 48000.0, 1024, 40, 0.0, 24000.0, True, False),
    ("slaney-16000-512-26-range", 16000.0, 512, 26, 80.0, 7600.0, False, True),
    ("htk-44100-4096-64-area", 44100.0, 4096, 64, 0.0, 22050.0, True, True),
    ("slaney-48000-240-12-peak", 48000.0, 240, 12, 300.0, 20000.0, False, False),
)
for name, rate, length, bands, fmin, fmax, htk, slaney in BANKS:
    weights, edges = _spectral.mel_filter_bank(numpy, rate, length, bands, fmin, fmax, htk, slaney)
    cases.append(_golden.case(f"bank-{name}", {
        "sampleRate": rate, "length": length, "bands": bands, "fmin": fmin, "fmax": fmax,
        "htk": 1 if htk else 0, "slaney": 1 if slaney else 0},
        {"weights": _golden.raw_array(TARGET, f"mel_bank_{name}.f64", weights, dtype="f64"),
         "edges": _golden.real_vector(edges)}))

# --- The mel power spectrogram of the fixtures --------------------------------------------------------
FRAME, HOP, BANDS = 2048, 512, 128
window = signal.get_window("hann", FRAME, fftbins=True)
weights, _ = _spectral.mel_filter_bank(numpy, _fixtures.SAMPLE_RATE, FRAME, BANDS, 0.0, _fixtures.SAMPLE_RATE / 2.0, False, True)
for name, samples in (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy))):
    power = numpy.abs(_spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, True)) ** 2
    mel = power @ weights.T
    cases.append(_golden.case(f"spectrogram-{name}", {
        "frame": FRAME, "hop": HOP, "bands": BANDS, "frames": int(mel.shape[0]), "sampleRate": _fixtures.SAMPLE_RATE},
        {"mel": _golden.raw_array(TARGET, f"mel_spectrogram_{name}.f64", mel, dtype="f64")}))

_golden.write(TARGET, "mel", cases)
