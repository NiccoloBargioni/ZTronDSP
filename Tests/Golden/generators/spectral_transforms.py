"""Golden vectors for the transform backend and the STFT step (WP-502, WP-504, STG-2).

Oracle: numpy.fft.rfft, every argument explicit.

The table of STG-2 names librosa.stft for the framings. librosa is not installed where these
vectors were generated, so the short-time transform is written here from its published
definition, with NumPy only:

    X[k, m] = Σ_n w[n] · y[k·hop + n] · e^(−j2πmn/M),   n = 0 … N − 1,   m = 0 … M/2

    causal    y = x                          frame k is x[k·hop : k·hop + N]      (center=False)
    centred   y = x reflected by N // 2 at   frame k is centred on x[k·hop]       (center=True,
              its start (numpy.pad, mode                                           pad_mode="reflect")
              "reflect": the edge sample is
              not repeated)

A streaming analysis has no end of signal: of the centred frames only those whose last sample
has arrived exist, k ≤ (len(x) − N // 2) / hop. The window is scipy.signal.get_window("hann", N,
fftbins=True) unless the case says otherwise, zero-padded after its samples when M > N.

Grid: lengths 16, 48, 80, 240, 1 024, 4 096; two framings. Tolerance: 1e-5 of the frame maximum.

    python3 spectral_transforms.py
"""
import _golden
import _spectral

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
LENGTHS = (16, 48, 80, 240, 1024, 4096)


def noise(count, seed):
    rng = numpy.random.default_rng(seed)
    return (0.5 * rng.standard_normal(count)).astype(numpy.float32)


# --- WP-502: the transform itself -----------------------------------------------------------------

cases = []
for length in LENGTHS:
    x = noise(length, 5020 + length)
    spectrum = numpy.fft.rfft(x.astype(numpy.float64), n=length, axis=-1, norm="backward")
    back = numpy.fft.irfft(spectrum, n=length, axis=-1, norm="backward")
    cases.append(_golden.case(f"rfft-{length}", {"length": length},
                              {"signal": _golden.real_vector(x), "spectrum": _golden.complex_vector(spectrum),
                               "inverse": _golden.real_vector(back)}))
_golden.write(TARGET, "fft", cases)

# --- WP-504: the short-time transform --------------------------------------------------------------


def stft(x, frame, hop, window, length, centred, factor):
    return _spectral.stft(numpy, x, frame, hop, window, length, centred, factor)


cases = []
signals, reals, imaginaries = [], [], []


def add(name, parameters, x, spectra):
    """Records one configuration. The signals and the spectra of all of them travel in three raw
    files, one after another; a case names its part of each by offset and count."""
    cases.append(_golden.case(name, {
        **parameters, "frames": int(spectra.shape[0]), "bins": int(spectra.shape[1]),
        "signalOffset": int(sum(len(s) for s in signals)), "signalCount": int(len(x)),
        "spectrumOffset": int(sum(r.size for r in reals))}, {}))
    signals.append(x)
    reals.append(spectra.real.ravel())
    imaginaries.append(spectra.imag.ravel())


for frame in LENGTHS:
    hop = frame // 4
    x = noise(4 * frame + 3, 5040 + frame)
    window = signal.get_window("hann", frame, fftbins=True)
    for centred in (False, True):
        name = f"{frame}-{'centered' if centred else 'causal'}"
        add(name, {"frame": frame, "hop": hop, "length": frame, "window": "hann", "centered": 1 if centred else 0,
                   "normalization": "none"},
            x, stft(x, frame, hop, window, frame, centred, 1.0))

# Zero-padding, another window, an odd hop, and the two normalisations.
x = noise(2000, 5049)
window = signal.get_window("hamming", 240, fftbins=True)
add("padded", {"frame": 240, "hop": 77, "length": 480, "window": "hamming", "centered": 0, "normalization": "none"},
    x, stft(x, 240, 77, window, 480, False, 1.0))
window = signal.get_window("hann", 1024, fftbins=True)
add("amplitude", {"frame": 1024, "hop": 256, "length": 1024, "window": "hann", "centered": 1, "normalization": "amplitude"},
    x, stft(x, 1024, 256, window, 1024, True, 2.0 / numpy.sum(window)))
add("power", {"frame": 1024, "hop": 256, "length": 2048, "window": "hann", "centered": 0, "normalization": "power"},
    x, stft(x, 1024, 256, window, 2048, False, numpy.sqrt(2.0 / (2048.0 * numpy.sum(window * window)))))

cases.append(_golden.case("data", {}, {
    "signals": _golden.raw_array(TARGET, "stft_signals.f32", numpy.concatenate(signals), dtype="f32"),
    "real": _golden.raw_array(TARGET, "stft_real.f64", numpy.concatenate(reals), dtype="f64"),
    "imaginary": _golden.raw_array(TARGET, "stft_imaginary.f64", numpy.concatenate(imaginaries), dtype="f64")}))
_golden.write(TARGET, "stft", cases)
