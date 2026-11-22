"""Golden vectors for the mel scale (WP-508, WP-535, STG-2).

Oracle: librosa 0.11.0, ORACLE FORM for each quantity: what is written is librosa's output, every
argument explicit, the input in float64, held first to the NumPy definition of _spectral.py
within 1e-12 of the largest value (both in double precision):

    the formulas      librosa.hz_to_mel(frequencies=f, htk=False)        Slaney: 3f/200 below 1 kHz,
                      librosa.hz_to_mel(frequencies=f, htk=True)         15 + 27·ln(f/1000)/ln 6.4 above;
                                                                         HTK: 2595·log10(1 + f/700)
    the filter bank   librosa.filters.mel(sr=…, n_fft=…, n_mels=…, fmin=…, fmax=…, htk=…,
                                          norm="slaney" | None, dtype=numpy.float64)
                      (dtype given: librosa's default is float32) and its edges,
                      librosa.mel_frequencies(n_mels=bands + 2, fmin=…, fmax=…, htk=…)
    the spectrogram   librosa.feature.melspectrogram(y=x, sr=22050.0, S=None, n_fft=2048,
                          hop_length=512, win_length=2048, window="hann", center=True,
                          pad_mode="reflect", power=2.0, n_mels=128, fmin=0.0, fmax=11025.0,
                          htk=False, norm="slaney", dtype=numpy.float64)
                      (the fixtures' rate, 22 050 Hz, and its Nyquist frequency)
                      transposed to frames × bands: weights @ |STFT|² of the centred framing an
                      offline tool uses, of which the frames a stream has, k ≤ (len − 1024)/512,
                      are written (spectral_transforms.py says why).

Read by ZTronDSPAnalysisTests (MelTests).
Tolerances (STG-2): conversions 1e-9 relative; weights 1e-6; the mel power spectrogram 1e-4 of the
frame maximum.

    python3 mel.py
"""
import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
cases = []

# --- The formulas ------------------------------------------------------------------------------------
hertz = numpy.array([0.0, 1.0, 50.0, 200.0, 440.0, 999.9, 1000.0, 1000.1, 2500.0, 4000.0, 8000.0, 11025.0, 16000.0, 24000.0])
slaney = librosa.hz_to_mel(frequencies=hertz, htk=False)
htk = librosa.hz_to_mel(frequencies=hertz, htk=True)
_golden.cross_check("hz_to_mel, Slaney", slaney, _spectral.hz_to_mel(numpy, hertz, False), 1e-12)
_golden.cross_check("hz_to_mel, HTK", htk, _spectral.hz_to_mel(numpy, hertz, True), 1e-12)
cases.append(_golden.case("formulas", {}, {
    "hertz": _golden.real_vector(hertz), "slaney": _golden.real_vector(slaney), "htk": _golden.real_vector(htk)}))

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
    weights = librosa.filters.mel(sr=rate, n_fft=length, n_mels=bands, fmin=fmin, fmax=fmax, htk=htk,
                                  norm="slaney" if slaney else None, dtype=numpy.float64)
    edges = librosa.mel_frequencies(n_mels=bands + 2, fmin=fmin, fmax=fmax, htk=htk)
    definition, definition_edges = _spectral.mel_filter_bank(numpy, rate, length, bands, fmin, fmax, htk, slaney)
    _golden.cross_check(f"filters.mel {name}", weights, definition, 1e-12)
    _golden.cross_check(f"mel_frequencies {name}", edges, definition_edges, 1e-12)
    cases.append(_golden.case(f"bank-{name}", {
        "sampleRate": rate, "length": length, "bands": bands, "fmin": fmin, "fmax": fmax,
        "htk": 1 if htk else 0, "slaney": 1 if slaney else 0},
        {"weights": _golden.raw_array(TARGET, f"mel_bank_{name}.f64", weights, dtype="f64"),
         "edges": _golden.real_vector(edges)}))

# --- The mel power spectrogram of the fixtures --------------------------------------------------------
FRAME, HOP, BANDS = 2048, 512, 128
RATE = _fixtures.SAMPLE_RATE
window = signal.get_window("hann", FRAME, fftbins=True)
weights, _ = _spectral.mel_filter_bank(numpy, RATE, FRAME, BANDS, 0.0, RATE / 2.0, False, True)
for name, samples in (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy))):
    count = (len(samples) - FRAME // 2) // HOP + 1
    mel = librosa.feature.melspectrogram(y=numpy.asarray(samples, dtype=numpy.float64), sr=RATE, S=None, n_fft=FRAME,
                                         hop_length=HOP, win_length=FRAME, window="hann", center=True, pad_mode="reflect",
                                         power=2.0, n_mels=BANDS, fmin=0.0, fmax=RATE / 2.0, htk=False, norm="slaney",
                                         dtype=numpy.float64).T[:count]
    definition = (numpy.abs(_spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, True)) ** 2) @ weights.T
    _golden.cross_check(f"melspectrogram {name}", mel, definition, 1e-12)
    cases.append(_golden.case(f"spectrogram-{name}", {
        "frame": FRAME, "hop": HOP, "bands": BANDS, "frames": int(mel.shape[0]), "sampleRate": RATE},
        {"mel": _golden.raw_array(TARGET, f"mel_spectrogram_{name}.f64", mel, dtype="f64")}))

_golden.write(TARGET, "mel", cases)
