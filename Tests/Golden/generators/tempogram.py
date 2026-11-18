"""Golden vectors for the tempograms (WP-526, WP-527, STG-2): the references of §6.9's
"frame-wise cosine similarity against the reference on fixtures generated with the same
arguments".

Written from the definitions of §6.9 with NumPy (_rhythm.py). No library computes these
tempograms as the specification defines them: each window of the novelty curve has its mean
removed and is tapered; the autocorrelation tempogram is its linear autocorrelation over its
value at lag 0, zeros where that value does not exceed the floor; the Fourier tempogram is the
magnitude of its DFT zero-padded to the fast length at or above resolution·window; both keep the
rows inside a range of tempi, in ascending tempo. librosa.feature.tempogram and
fourier_tempogram, which a reader may expect here, keep the mean, return every row and (the
second) return complex values; _rhythm.py states the differences.

Two fixtures:

    curve    a synthetic novelty curve of 600 values at 93.75 values per second (48 kHz, hop
             512): pulses at 120 beats per minute, off-beats, a drift and seeded noise. It is
             written beside the vectors and fed to the step as it is, so the windows of the
             default length, 384 values, are exercised without minutes of audio.
    music    the novelty curve of the music fixture (onset_strength.py: frame 1 024, hop 256,
             64 bands, centred frames, lag 1, no maximum filter, floor -80 dB), for the chain
             from samples to a tempogram; the fixture lasts two seconds, so the window is 64.

Windows are those a stream produces (_rhythm.tempogram_windows): causal, or centred with the
curve led in by a linear ramp.

Tolerance: frame-wise cosine similarity >= 0.99.

    python3 tempogram.py
"""
import _golden
import _fixtures
import _rhythm
import _spectral

numpy, scipy = _golden.oracle()
from scipy import ndimage, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
FLOOR = 1e-10
cases = []


def taper(name, window):
    return signal.get_window(name, window, fftbins=True)


def add(prefix, onset, feature_rate, method, window, taper_name, low, high, centred, resolution=4):
    windows = _rhythm.tempogram_windows(numpy, onset, window, centred)
    shape = taper(taper_name, window)
    if method == "autocorrelation":
        columns, tempi = _rhythm.autocorrelation_tempogram(numpy, windows, shape, feature_rate, low, high, FLOOR)
    else:
        columns, tempi = _rhythm.fourier_tempogram(numpy, windows, shape, feature_rate, low, high, resolution)
    alignment = "centred" if centred else "causal"
    name = f"{prefix}-{method}-{window}-{taper_name}-{int(low)}-{int(high)}-{alignment}" + (f"-x{resolution}" if method == "fourier" else "")
    cases.append(_golden.case(name, {
        "method": method, "window": window, "taper": taper_name, "low": low, "high": high, "centred": 1 if centred else 0,
        "resolution": resolution, "floor": FLOOR, "featureRate": feature_rate, "frames": int(columns.shape[0]), "rows": int(columns.shape[1])},
        {"columns": _golden.raw_array(TARGET, f"tempogram_{name}.f32", columns, dtype="f32"),
         "beatsPerMinute": _golden.real_vector(tempi)}))


# --- A synthetic novelty curve ------------------------------------------------------------------------
RATE = 48000.0 / 512.0
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
    add("curve", onset, RATE, "autocorrelation", 384, "hann", 30.0, 300.0, centred)
    add("curve", onset, RATE, "fourier", 384, "hann", 30.0, 300.0, centred)
add("curve", onset, RATE, "autocorrelation", 101, "hamming", 60.0, 240.0, True)
add("curve", onset, RATE, "fourier", 101, "hamming", 60.0, 240.0, False, resolution=8)
add("curve", onset, RATE, "fourier", 128, "hann", 30.0, 300.0, True, resolution=1)

# --- The chain on the music fixture -------------------------------------------------------------------
FRAME, HOP, BANDS = 1024, 256, 64
window = signal.get_window("hann", FRAME, fftbins=True)
weights, _ = _spectral.mel_filter_bank(numpy, _fixtures.SAMPLE_RATE, FRAME, BANDS, 0.0, _fixtures.SAMPLE_RATE / 2.0, False, True)
power = numpy.abs(_spectral.stft(numpy, _fixtures.music(numpy), FRAME, HOP, window, FRAME, True)) ** 2
music = _rhythm.onset_strength(numpy, ndimage, _rhythm.power_to_decibels(numpy, power @ weights.T), 1, 1, -80.0)
cases.append(_golden.case("music", {
    "frame": FRAME, "hop": HOP, "bands": BANDS, "featureRate": _fixtures.SAMPLE_RATE / HOP, "count": int(music.shape[0])},
    {"onset": _golden.real_vector(music)}))
for centred in (False, True):
    add("music", music, _fixtures.SAMPLE_RATE / HOP, "autocorrelation", 64, "hann", 30.0, 300.0, centred)
    add("music", music, _fixtures.SAMPLE_RATE / HOP, "fourier", 64, "hann", 30.0, 300.0, centred)

_golden.write(TARGET, "tempogram", cases)
