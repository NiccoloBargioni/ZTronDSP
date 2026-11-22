"""Golden vectors for the tempograms (WP-526, WP-527, STG-2): the references of §6.9's
"frame-wise cosine similarity against the reference on fixtures generated with the same
arguments".

Oracle: librosa 0.11.0, ORACLE FORM with the conversions written out. §6.9 departs from librosa's
tempograms in one documented way: each window of the novelty curve has its MEAN REMOVED before it
is tapered (librosa.feature.tempogram and fourier_tempogram keep it; on these fixtures the
cosine similarity between the two readings is far below 0.99, so they are not the same
quantity). The specification's tempogram is reached from librosa by calling librosa's tempogram
on each mean-removed window, every argument explicit, in float64:

    windows   librosa.util.frame(c, frame_length=W, hop_length=1, axis=-1, writeable=False,
              subok=False), c the curve, or
              (centred) the curve padded as librosa.feature.tempogram(center=True) pads it,
              numpy.pad(curve, (W//2, W//2), mode="linear_ramp", end_values=(0, 0)); of the
              centred windows the stream has those whose last value has arrived, the first ones
    segment   s = window − mean(window)                                    (the conversion)
    autocorrelation tempogram, column of a window:
              librosa.util.normalize(
                  librosa.feature.tempogram(y=None, sr=22050.0, onset_envelope=s, hop_length=hop,
                                            win_length=W, center=False, window=taper, norm=None),
                  norm=numpy.inf, axis=0, threshold=1e-10, fill=False)
              (the autocorrelation's largest value is its value at lag 0: normalised by lag 0,
              and zeros where that value is below the floor, §6.9); the rows are the lags ℓ
              with 30 … 300 (or the case's range) ∋ 60·featureRate/ℓ, in ascending tempo
    Fourier tempogram, column of a window:
              numpy.abs(librosa.feature.fourier_tempogram(y=None, sr=22050.0,
                  onset_envelope=[s, L − W zeros], hop_length=hop, win_length=L, center=False,
                  window=[librosa.filters.get_window(taper, W, fftbins=True), L − W zeros]))
              with L the fast length at or above resolution·W (the zero-padding of §6.9, as
              spectral_transforms.py pads a frame); the rows are the bins k with the range ∋
              60·k·featureRate/L
    sr is the fixtures' rate, 22 050 Hz, for both fixtures: given onset_envelope, neither
    function reads sr or hop_length (they make a curve from y), so the curve's feature rate,
    93.75 values per second, enters only through the rows' tempi.

The centred lead-in is librosa.feature.tempogram's linear ramp for both tempograms, which is how
the package's step centres them (librosa.feature.fourier_tempogram would lead in with zeros, its
STFT padding).

Cross-check, before anything is written, within 1e-12 of the largest value (double precision):
the definitions of _rhythm.py (Grosche, Müller & Kurth 2010; Grosche & Müller 2011), and, for
the music chain, the onset strength of _rhythm.py on the spectrum of _spectral.py.

Two fixtures:

    curve    a synthetic novelty curve of 600 values at 93.75 values per second (48 kHz, hop
             512): pulses at 120 beats per minute, off-beats, a drift and seeded noise. It is
             written beside the vectors and fed to the step as it is, so the windows of the
             default length, 384 values, are exercised without minutes of audio.
    music    the novelty curve of the music fixture, librosa's (onset_strength.py: frame 1 024,
             hop 256, 64 bands, centred frames, lag 1, no maximum filter, floor −80 dB), for the
             chain from samples to a tempogram; the fixture lasts two seconds, so the window is 64.

Read by ZTronDSPAnalysisTests (TempogramTests). Tolerance (§6.9): frame-wise cosine similarity
>= 0.99.

    python3 tempogram.py
"""
import _golden
import _fixtures
import _rhythm
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
from scipy import ndimage, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
SAMPLE_RATE = _fixtures.SAMPLE_RATE
FLOOR = 1e-10
cases = []


def segments(onset, window, centred):
    """The mean-removed windows of the curve a stream has, one per row, framed by librosa."""
    curve = numpy.asarray(onset, dtype=numpy.float64)
    padded = numpy.pad(curve, (window // 2, window // 2), mode="linear_ramp", end_values=(0, 0)) if centred else curve
    framed = librosa.util.frame(padded, frame_length=window, hop_length=1, axis=-1, writeable=False, subok=False).T
    count = len(curve) + window // 2 - window + 1 if centred else len(curve) - window + 1
    framed = framed[:count]
    return framed - framed.mean(axis=1, keepdims=True)


def librosa_autocorrelation(onset, hop, feature_rate, window, taper_name, low, high, centred):
    lags = [lag for lag in range(window - 1, 0, -1) if low <= 60.0 * feature_rate / lag <= high]
    columns = []
    for segment in segments(onset, window, centred):
        raw = librosa.feature.tempogram(y=None, sr=SAMPLE_RATE, onset_envelope=segment, hop_length=hop, win_length=window,
                                        center=False, window=taper_name, norm=None)
        column = librosa.util.normalize(raw, norm=numpy.inf, axis=0, threshold=FLOOR, fill=False)[:, 0]
        columns.append(column[lags])
    return numpy.array(columns), [60.0 * feature_rate / lag for lag in lags]


def librosa_fourier(onset, hop, feature_rate, window, taper_name, low, high, centred, resolution):
    length = _rhythm.next_fast_length(resolution * window)
    spacing = 60.0 * feature_rate / length
    bins = [k for k in range(1, length // 2 + 1) if low <= k * spacing <= high]
    taper = numpy.concatenate([librosa.filters.get_window(taper_name, window, fftbins=True), numpy.zeros(length - window)])
    columns = []
    for segment in segments(onset, window, centred):
        spectrum = librosa.feature.fourier_tempogram(y=None, sr=SAMPLE_RATE, onset_envelope=numpy.concatenate([segment, numpy.zeros(length - window)]),
                                                     hop_length=hop, win_length=length, center=False, window=taper)
        columns.append(numpy.abs(spectrum[:, 0])[bins])
    return numpy.array(columns), [k * spacing for k in bins]


def add(prefix, onset, hop, feature_rate, method, window, taper_name, low, high, centred, resolution=4):
    alignment = "centred" if centred else "causal"
    name = f"{prefix}-{method}-{window}-{taper_name}-{int(low)}-{int(high)}-{alignment}" + (f"-x{resolution}" if method == "fourier" else "")
    windows = _rhythm.tempogram_windows(numpy, onset, window, centred)
    shape = signal.get_window(taper_name, window, fftbins=True)
    if method == "autocorrelation":
        columns, tempi = librosa_autocorrelation(onset, hop, feature_rate, window, taper_name, low, high, centred)
        definition, definition_tempi = _rhythm.autocorrelation_tempogram(numpy, windows, shape, feature_rate, low, high, FLOOR)
    else:
        columns, tempi = librosa_fourier(onset, hop, feature_rate, window, taper_name, low, high, centred, resolution)
        definition, definition_tempi = _rhythm.fourier_tempogram(numpy, windows, shape, feature_rate, low, high, resolution)
    _golden.cross_check(f"tempogram {name}", columns, definition, 1e-12)
    _golden.cross_check(f"tempogram {name}, beats per minute", tempi, definition_tempi, 1e-12)
    cases.append(_golden.case(name, {
        "method": method, "window": window, "taper": taper_name, "low": low, "high": high, "centred": 1 if centred else 0,
        "resolution": resolution, "floor": FLOOR, "featureRate": feature_rate, "frames": int(columns.shape[0]), "rows": int(columns.shape[1])},
        {"columns": _golden.raw_array(TARGET, f"tempogram_{name}.f32", columns, dtype="f32"),
         "beatsPerMinute": _golden.real_vector(tempi)}))


# --- A synthetic novelty curve ------------------------------------------------------------------------
HOP = 512
RATE = 48000.0 / HOP
COUNT = 600
rng = numpy.random.default_rng(20261526)
t = numpy.arange(COUNT)
curve = 0.3 + 0.2 * numpy.sin(2.0 * numpy.pi * t / 410.0) + 0.15 * rng.random(COUNT)
period = 60.0 * RATE / 120.0                      # 46.875 values: 120 beats per minute
for beat in range(int(COUNT / period) + 1):
    at = int(round(beat * period))
    if at < COUNT:
        curve[at] += 6.0 + 2.0 * rng.random()
    off = int(round((beat + 0.5) * period))
    if off < COUNT:
        curve[off] += 2.0 + rng.random()
curve = curve.astype(numpy.float32)
stored = _golden.raw_array(TARGET, "tempogram_curve.f32", curve, dtype="f32")
cases.append(_golden.case("curve", {"featureRate": RATE, "count": COUNT}, {"curve": stored}))
onset = curve.astype(numpy.float64)

for centred in (False, True):
    add("curve", onset, HOP, RATE, "autocorrelation", 384, "hann", 30.0, 300.0, centred)
    add("curve", onset, HOP, RATE, "fourier", 384, "hann", 30.0, 300.0, centred)
add("curve", onset, HOP, RATE, "autocorrelation", 101, "hamming", 60.0, 240.0, True)
add("curve", onset, HOP, RATE, "fourier", 101, "hamming", 60.0, 240.0, False, resolution=8)
add("curve", onset, HOP, RATE, "fourier", 128, "hann", 30.0, 300.0, True, resolution=1)

# --- The chain on the music fixture -------------------------------------------------------------------
FRAME, MUSIC_HOP, BANDS = 1024, 256, 64
samples = _fixtures.music(numpy)
count = (len(samples) - FRAME // 2) // MUSIC_HOP + 1
mel = librosa.feature.melspectrogram(y=numpy.asarray(samples, dtype=numpy.float64), sr=SAMPLE_RATE, S=None, n_fft=FRAME,
                                     hop_length=MUSIC_HOP, win_length=FRAME, window="hann", center=True, pad_mode="reflect",
                                     power=2.0, n_mels=BANDS, fmin=0.0, fmax=SAMPLE_RATE / 2.0, htk=False, norm="slaney",
                                     dtype=numpy.float64)[:, :count]
music = librosa.onset.onset_strength(y=None, sr=SAMPLE_RATE, S=numpy.maximum(librosa.power_to_db(S=mel, ref=1.0, amin=1e-16, top_db=None), -80.0),
                                     lag=1, max_size=1, ref=None, detrend=False, center=False, feature=None, aggregate=numpy.mean)
window = signal.get_window("hann", FRAME, fftbins=True)
weights, _ = _spectral.mel_filter_bank(numpy, SAMPLE_RATE, FRAME, BANDS, 0.0, SAMPLE_RATE / 2.0, False, True)
power = numpy.abs(_spectral.stft(numpy, samples, FRAME, MUSIC_HOP, window, FRAME, True)) ** 2
_golden.cross_check("onset_strength music", music,
                    _rhythm.onset_strength(numpy, ndimage, _rhythm.power_to_decibels(numpy, power @ weights.T), 1, 1, -80.0), 1e-12)
cases.append(_golden.case("music", {
    "frame": FRAME, "hop": MUSIC_HOP, "bands": BANDS, "featureRate": SAMPLE_RATE / MUSIC_HOP, "count": int(music.shape[0])},
    {"onset": _golden.real_vector(music)}))
for centred in (False, True):
    add("music", music, MUSIC_HOP, SAMPLE_RATE / MUSIC_HOP, "autocorrelation", 64, "hann", 30.0, 300.0, centred)
    add("music", music, MUSIC_HOP, SAMPLE_RATE / MUSIC_HOP, "fourier", 64, "hann", 30.0, 300.0, centred)

_golden.write(TARGET, "tempogram", cases)
