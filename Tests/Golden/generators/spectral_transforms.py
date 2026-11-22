"""Golden vectors for the transform backend and the STFT step (WP-502, WP-504, STG-2).

The transform (fft.json). Oracle: numpy.fft.rfft / irfft, every argument explicit.

The short-time transform (stft.json). Oracle: librosa 0.11.0, ORACLE FORM: the frames written
are librosa.stft's, every argument explicit, the input in float64,

    librosa.stft(y=x, n_fft=M, hop_length=hop, win_length=M, window=w, center=centred,
                 dtype=numpy.complex128, pad_mode="reflect", out=None)        (bins × frames)

transposed to frames × bins. `w` is the name ("hann", "hamming": librosa takes
scipy.signal.get_window(name, M, fftbins=True), periodic) when M = N; when the frame is
zero-padded to M > N it is the array [get_window(name, N, fftbins=True), M − N zeros], because
librosa's own win_length < n_fft would centre the window in the frame, and the signal is extended
by M − N zeros at its end, so that librosa counts the frames of the N-sample framing (the zeros
meet the zeros of the window). A window normalisation is a factor on every value, applied to
librosa's output: 2/Σw (amplitude), √(2/(M·Σw²)) (power).

A streaming analysis has no end of signal: of librosa's centred frames (1 + len(x)/hop, the
signal reflected by M/2 at both ends) the stream has those whose last sample has arrived,
k ≤ (len(x) − N/2)/hop, the first ones, which are written; the end's frames are not.

Cross-check, before anything is written: the definition (_spectral.stft, NumPy)

    X[k, m] = Σ_n factor·w[n]·y[k·hop + n]·e^(−j2πmn/M),   n = 0 … N − 1,   m = 0 … M/2

    causal    y = x                          frame k is x[k·hop : k·hop + N]
    centred   y = x reflected by N/2 at its  frame k is centred on x[k·hop]
              start (numpy.pad "reflect",
              the edge sample not repeated)

must equal librosa's frames within 1e-12 of the largest value (both in double precision; it
measures 1.4e-16).

Grid: lengths 16, 48, 80, 240, 1 024, 4 096; two framings; zero-padding with a Hamming window and
an odd hop; the two normalisations. Read by ZTronDSPAnalysisTests (STFTTests); tolerance 1e-5 of
the frame maximum (STG-2).

    python3 spectral_transforms.py
"""
import _golden
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
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


def librosa_stft(x, frame, hop, name, length, centred, factor):
    """librosa.stft of the framing, frames × bins: for a stream, the frames whose last sample has
    arrived (centred), every one of them (causal)."""
    y = numpy.asarray(x, dtype=numpy.float64)
    window = name
    if length > frame and centred:
        raise ValueError("librosa centres its frame of n_fft samples: a centred, zero-padded framing has no librosa call here")
    if length > frame:
        window = numpy.concatenate([signal.get_window(name, frame, fftbins=True), numpy.zeros(length - frame)])
        y = numpy.concatenate([y, numpy.zeros(length - frame)])
    spectra = librosa.stft(y=y, n_fft=length, hop_length=hop, win_length=length, window=window, center=centred,
                           dtype=numpy.complex128, pad_mode="reflect", out=None).T
    count = (len(x) - frame // 2) // hop + 1 if centred else (len(x) - frame) // hop + 1
    return factor * spectra[:count]


def stft(name, x, frame, hop, window_name, length, centred, factor):
    """librosa's frames, held to the definition before they are written."""
    window = signal.get_window(window_name, frame, fftbins=True)
    definition = _spectral.stft(numpy, x, frame, hop, window, length, centred, factor)
    spectra = librosa_stft(x, frame, hop, window_name, length, centred, factor)
    _golden.cross_check(f"stft {name}", spectra, definition, 1e-12)
    return spectra


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
    for centred in (False, True):
        name = f"{frame}-{'centered' if centred else 'causal'}"
        add(name, {"frame": frame, "hop": hop, "length": frame, "window": "hann", "centered": 1 if centred else 0,
                   "normalization": "none"},
            x, stft(name, x, frame, hop, "hann", frame, centred, 1.0))

# Zero-padding, another window, an odd hop, and the two normalisations.
x = noise(2000, 5049)
add("padded", {"frame": 240, "hop": 77, "length": 480, "window": "hamming", "centered": 0, "normalization": "none"},
    x, stft("padded", x, 240, 77, "hamming", 480, False, 1.0))
hann = signal.get_window("hann", 1024, fftbins=True)
add("amplitude", {"frame": 1024, "hop": 256, "length": 1024, "window": "hann", "centered": 1, "normalization": "amplitude"},
    x, stft("amplitude", x, 1024, 256, "hann", 1024, True, 2.0 / numpy.sum(hann)))
add("power", {"frame": 1024, "hop": 256, "length": 2048, "window": "hann", "centered": 0, "normalization": "power"},
    x, stft("power", x, 1024, 256, "hann", 2048, False, numpy.sqrt(2.0 / (2048.0 * numpy.sum(hann * hann)))))

cases.append(_golden.case("data", {}, {
    "signals": _golden.raw_array(TARGET, "stft_signals.f32", numpy.concatenate(signals), dtype="f32"),
    "real": _golden.raw_array(TARGET, "stft_real.f64", numpy.concatenate(reals), dtype="f64"),
    "imaginary": _golden.raw_array(TARGET, "stft_imaginary.f64", numpy.concatenate(imaginaries), dtype="f64")}))
_golden.write(TARGET, "stft", cases)
