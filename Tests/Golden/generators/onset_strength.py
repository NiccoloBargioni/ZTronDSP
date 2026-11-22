"""Golden vectors for the onset strength (WP-525, STG-2).

Oracle: librosa 0.11.0, ORACLE FORM. The table of STG-2 names librosa.onset.onset_strength, "with
the same floor and no clipping relative to the maximum". What is written is librosa's output,
every argument explicit, the input in float64:

    M = librosa.feature.melspectrogram(y=x, sr=22050.0, S=None, n_fft=frame, hop_length=hop,
            win_length=frame, window="hann", center=centred, pad_mode="reflect", power=2.0,
            n_mels=bands, fmin=0.0, fmax=11025.0, htk=False, norm="slaney", dtype=numpy.float64)
    S = numpy.maximum(librosa.power_to_db(S=M, ref=1.0, amin=1e-16, top_db=None), floor)
    o = librosa.onset.onset_strength(y=None, sr=22050.0, S=S, lag=lag, max_size=max_size, ref=None,
            detrend=False, center=False, feature=None, aggregate=numpy.mean)

(22 050 Hz is the fixtures' rate, 11 025 Hz its Nyquist frequency.)

The conversions, written out: power_to_db with ref=1.0, amin=1e-16 and top_db=None is the
package's 10·log10(max(p, 1e-16)), nothing clipped relative to the maximum; the floor is the
specification's, applied to librosa's decibels (librosa has no floor of its own: its amin would
shift every value by the floor when the floor is above 0 dB). center=False: the frames are
stamped with their own times, no shift by half a frame. Of a centred spectrogram the frames a
stream has are kept (spectral_transforms.py).

Cross-check, before anything is written, within 1e-12 of the largest value (double precision):
the definition of _rhythm.onset_strength (§6.9; Böck & Widmer 2013),

    o[t] = mean over bands of max(0, S[f, t] − R[f, t − lag]),   0 for t < lag,

R being S or S under scipy.ndimage.maximum_filter1d along frequency, on the spectrum of the
definitions of _spectral.py.

    music    frame 2 048, hop 512, 128 bands, the centred frames an offline tool uses
    speech   frame 1 024, hop 256, 64 bands, causal frames: the fixture pauses, and a frame that
             lies inside a pause is silence, which the floor has to hold

Read by ZTronDSPAnalysisTests (OnsetStrengthTests). Tolerance (STG-2): 1e-3 of the largest value
of the curve.

    python3 onset_strength.py
"""
import _golden
import _fixtures
import _rhythm
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
from scipy import ndimage, signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
RATE = _fixtures.SAMPLE_RATE
cases = []

FIXTURES = (
    # name, samples, frame, hop, bands, centred, (lag, max size, floor in dB) …
    ("music", _fixtures.music(numpy), 2048, 512, 128, True, ((1, 1, -80.0), (1, 3, -80.0), (2, 1, 0.0), (3, 5, 10.0), (1, 4, -80.0))),
    ("speech", _fixtures.speech(numpy), 1024, 256, 64, False, ((1, 1, -80.0), (2, 3, -80.0), (1, 1, -20.0))),
)
for name, samples, frame, hop, bands, centred, grid in FIXTURES:
    count = (len(samples) - frame // 2) // hop + 1 if centred else (len(samples) - frame) // hop + 1
    mel = librosa.feature.melspectrogram(y=numpy.asarray(samples, dtype=numpy.float64), sr=RATE, S=None, n_fft=frame,
                                         hop_length=hop, win_length=frame, window="hann", center=centred, pad_mode="reflect",
                                         power=2.0, n_mels=bands, fmin=0.0, fmax=RATE / 2.0, htk=False, norm="slaney",
                                         dtype=numpy.float64)[:, :count]
    decibels = librosa.power_to_db(S=mel, ref=1.0, amin=1e-16, top_db=None)

    window = signal.get_window("hann", frame, fftbins=True)
    weights, _ = _spectral.mel_filter_bank(numpy, RATE, frame, bands, 0.0, RATE / 2.0, False, True)
    power = numpy.abs(_spectral.stft(numpy, samples, frame, hop, window, frame, centred)) ** 2
    definition_decibels = _rhythm.power_to_decibels(numpy, power @ weights.T)
    for lag, max_size, floor in grid:
        onset = librosa.onset.onset_strength(y=None, sr=RATE, S=numpy.maximum(decibels, floor), lag=lag, max_size=max_size,
                                             ref=None, detrend=False, center=False, feature=None, aggregate=numpy.mean)
        case = f"{name}-lag{lag}-max{max_size}-floor{int(floor)}"
        _golden.cross_check(f"onset_strength {case}", onset,
                            _rhythm.onset_strength(numpy, ndimage, definition_decibels, lag, max_size, floor), 1e-12)
        cases.append(_golden.case(case, {
            "fixture": name, "frame": frame, "hop": hop, "bands": bands, "centred": 1 if centred else 0,
            "lag": lag, "maxSize": max_size, "floor": floor, "frames": int(onset.shape[0]),
            # How much of the spectrogram lies under the floor: a case where none does says
            # nothing about the floor.
            "flooredShare": float(numpy.mean(decibels < floor)),
            "sampleRate": RATE},
            {"onset": _golden.real_vector(onset)}))

_golden.write(TARGET, "onset_strength", cases)
