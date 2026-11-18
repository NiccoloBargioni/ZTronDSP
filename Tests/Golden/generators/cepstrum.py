"""Golden vectors for the cepstra and the cepstral coefficients (WP-509, WP-512, STG-2).

Oracle: NumPy, from the definitions; SciPy's DCT for the coefficients.

    real cepstrum     irfft(ln max(|X|, floor))                    quefrencies 0 … N/2
    power cepstrum    irfft(ln max(|X|², floor))²                  quefrencies 0 … N/2
    coefficients      scipy.fft.dct(type=2, norm="ortho") of the mel spectrum in decibels,
                      10·log10(max(S, 1e-16)), of which the first `count` are kept

X is the STFT of the fixture (_spectral.stft; causal frames for the cepstra, the centred frames
of an offline tool for the coefficients). The table of STG-2 names librosa.feature.mfcc, which is
not installed where these vectors were generated: the coefficients are written from its published
definition (the orthonormal DCT-II of a log-mel spectrogram, lifter 0). The decibel conversion is
the package's own, a floor at −160 dB and no clipping relative to the maximum, not the defaults of
librosa.power_to_db.

Tolerances: cepstra 1e-4 of the frame maximum; coefficients 1e-3.

    python3 cepstrum.py
"""
import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()
from scipy import fft, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
FLOOR = 1e-10
cases = []

# --- Real and power cepstrum -------------------------------------------------------------------------
FRAME, HOP = 1024, 512
window = signal.get_window("hann", FRAME, fftbins=True)
for name, samples in (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy))):
    spectrum = _spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, False)
    magnitude = numpy.abs(spectrum)
    real = numpy.fft.irfft(numpy.log(numpy.maximum(magnitude, FLOOR)), n=FRAME, axis=-1, norm="backward")[:, :FRAME // 2 + 1]
    power = numpy.fft.irfft(numpy.log(numpy.maximum(magnitude ** 2, FLOOR)), n=FRAME, axis=-1, norm="backward")[:, :FRAME // 2 + 1] ** 2
    cases.append(_golden.case(f"cepstrum-{name}", {
        "frame": FRAME, "hop": HOP, "floor": FLOOR, "frames": int(real.shape[0]), "sampleRate": _fixtures.SAMPLE_RATE},
        {"real": _golden.raw_array(TARGET, f"cepstrum_real_{name}.f64", real, dtype="f64"),
         "power": _golden.raw_array(TARGET, f"cepstrum_power_{name}.f64", power, dtype="f64")}))

# --- Mel-frequency cepstral coefficients --------------------------------------------------------------
FRAME, HOP = 2048, 512
window = signal.get_window("hann", FRAME, fftbins=True)
for name, samples in (("speech", _fixtures.speech(numpy)), ("music", _fixtures.music(numpy))):
    power = numpy.abs(_spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, True)) ** 2
    for bands, count in ((40, 13), (64, 20), (128, 128), (26, 26)):
        weights, _ = _spectral.mel_filter_bank(numpy, _fixtures.SAMPLE_RATE, FRAME, bands, 0.0, _fixtures.SAMPLE_RATE / 2.0, False, True)
        decibels = 10.0 * numpy.log10(numpy.maximum(power @ weights.T, 1e-16))
        coefficients = fft.dct(decibels, type=2, n=bands, axis=-1, norm="ortho")[:, :count]
        cases.append(_golden.case(f"mfcc-{name}-{bands}-{count}", {
            "frame": FRAME, "hop": HOP, "bands": bands, "count": count, "frames": int(coefficients.shape[0]),
            "sampleRate": _fixtures.SAMPLE_RATE},
            {"coefficients": _golden.raw_array(TARGET, f"mfcc_{name}_{bands}_{count}.f64", coefficients, dtype="f64")}))

_golden.write(TARGET, "cepstrum", cases)
