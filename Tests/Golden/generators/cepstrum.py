"""Golden vectors for the cepstra and the cepstral coefficients (WP-509, WP-512, STG-2).

The cepstra (WP-509). The table of STG-2 names "NumPy from the definitions" for them:

    real cepstrum     irfft(ln max(|X|, floor))                    quefrencies 0 … N/2
    power cepstrum    irfft(ln max(|X|², floor))²                  quefrencies 0 … N/2

evaluated with NumPy on X, the causal frames of the fixture from librosa 0.11.0 (oracle form):

    librosa.stft(y=x, n_fft=1024, hop_length=512, win_length=1024, window="hann", center=False,
                 dtype=numpy.complex128, pad_mode="reflect", out=None)

The coefficients (WP-512). Oracle: librosa 0.11.0, ORACLE FORM: what is written is librosa's,

    librosa.feature.mfcc(y=None, sr=22050.0, S=librosa.power_to_db(S=M, ref=1.0, amin=1e-16, top_db=None),
                         n_mfcc=count, dct_type=2, norm="ortho", lifter=0, mel_norm="slaney")

with M the mel power spectrogram of mel.py with `bands` bands (librosa.feature.melspectrogram,
sr=22050.0 the fixtures' rate, the centred framing, n_fft 2048, hop 512, a periodic Hann window,
reflect padding, power 2, 0 Hz to the Nyquist frequency, 11 025 Hz, Slaney's formula and
normalisation, float64), of which the frames a stream has are written. Given S, mfcc reads
neither sr nor mel_norm (they make M from y); they are passed because every argument is. The decibel conversion is the package's, a floor at −160 dB and nothing clipped relative
to the maximum: power_to_db with ref=1.0, amin=1e-16 and top_db=None is exactly
10·log10(max(p, 1e-16)), so no convention of librosa's is left to convert.

Cross-checks, before anything is written, within 1e-12 of the largest value (double precision
throughout): librosa's frames against the definition of the STFT (_spectral.stft), and the
coefficients against the orthonormal DCT-II (scipy.fft.dct) of 10·log10(max(weights @ |X|²,
1e-16)) computed from the definitions of _spectral.py.

Read by ZTronDSPAnalysisTests (CepstrumTests, CepstralCoefficientTests). Tolerances (STG-2):
cepstra 1e-4 of the frame maximum; coefficients 1e-3.

    python3 cepstrum.py
"""
import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
from scipy import fft, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
RATE = _fixtures.SAMPLE_RATE
FLOOR = 1e-10
cases = []
FIXTURES = (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy)))

# --- Real and power cepstrum -------------------------------------------------------------------------
FRAME, HOP = 1024, 512
window = signal.get_window("hann", FRAME, fftbins=True)
for name, samples in FIXTURES:
    spectrum = librosa.stft(y=numpy.asarray(samples, dtype=numpy.float64), n_fft=FRAME, hop_length=HOP, win_length=FRAME,
                            window="hann", center=False, dtype=numpy.complex128, pad_mode="reflect", out=None).T
    _golden.cross_check(f"stft {name}", spectrum, _spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, False), 1e-12)
    magnitude = numpy.abs(spectrum)
    real = numpy.fft.irfft(numpy.log(numpy.maximum(magnitude, FLOOR)), n=FRAME, axis=-1, norm="backward")[:, :FRAME // 2 + 1]
    power = numpy.fft.irfft(numpy.log(numpy.maximum(magnitude ** 2, FLOOR)), n=FRAME, axis=-1, norm="backward")[:, :FRAME // 2 + 1] ** 2
    cases.append(_golden.case(f"cepstrum-{name}", {
        "frame": FRAME, "hop": HOP, "floor": FLOOR, "frames": int(real.shape[0]), "sampleRate": RATE},
        {"real": _golden.raw_array(TARGET, f"cepstrum_real_{name}.f64", real, dtype="f64"),
         "power": _golden.raw_array(TARGET, f"cepstrum_power_{name}.f64", power, dtype="f64")}))

# --- Mel-frequency cepstral coefficients --------------------------------------------------------------
FRAME, HOP = 2048, 512
window = signal.get_window("hann", FRAME, fftbins=True)
for name, samples in FIXTURES:
    count_frames = (len(samples) - FRAME // 2) // HOP + 1
    power = numpy.abs(_spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, True)) ** 2
    for bands, count in ((40, 13), (64, 20), (128, 128), (26, 26)):
        mel = librosa.feature.melspectrogram(y=numpy.asarray(samples, dtype=numpy.float64), sr=RATE, S=None, n_fft=FRAME,
                                             hop_length=HOP, win_length=FRAME, window="hann", center=True, pad_mode="reflect",
                                             power=2.0, n_mels=bands, fmin=0.0, fmax=RATE / 2.0, htk=False, norm="slaney",
                                             dtype=numpy.float64)
        coefficients = librosa.feature.mfcc(y=None, sr=RATE, S=librosa.power_to_db(S=mel, ref=1.0, amin=1e-16, top_db=None),
                                            n_mfcc=count, dct_type=2, norm="ortho", lifter=0, mel_norm="slaney").T[:count_frames]
        weights, _ = _spectral.mel_filter_bank(numpy, RATE, FRAME, bands, 0.0, RATE / 2.0, False, True)
        decibels = 10.0 * numpy.log10(numpy.maximum(power @ weights.T, 1e-16))
        definition = fft.dct(decibels, type=2, n=bands, axis=-1, norm="ortho")[:, :count]
        _golden.cross_check(f"mfcc {name} {bands} {count}", coefficients, definition, 1e-12)
        cases.append(_golden.case(f"mfcc-{name}-{bands}-{count}", {
            "frame": FRAME, "hop": HOP, "bands": bands, "count": count, "frames": int(coefficients.shape[0]),
            "sampleRate": RATE},
            {"coefficients": _golden.raw_array(TARGET, f"mfcc_{name}_{bands}_{count}.f64", coefficients, dtype="f64")}))

_golden.write(TARGET, "cepstrum", cases)
