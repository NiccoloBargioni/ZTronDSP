"""Golden vectors for the constant-Q transform and chroma (WP-517 … WP-524, STG-2).

The table of STG-2 names librosa for the spectral packages. librosa is not installed where
these vectors were generated, so every reference here is written from the published
definitions with NumPy only, evaluated directly, densely and in double precision. Nothing of
the method under test (octave recursion, half-band decimation, sparse kernels) is used: the
transform is the sum over the samples of the signal that defines it.

    geometry      f_k = fmin * 2^((k + tuning) / B),  alpha = 2^(1/B) - 1,  Q = filterScale / alpha,
                  N_k = ceil(Q * fs / (f_k + gamma / alpha))                          (section 6.8)

    atom          a_k[m] = (2 / sum(w)) * w(1/2 + m / N_k) * exp(j 2 pi f_k m / fs)
                  for m = -floor(N_k / 2) ... ceil(N_k / 2) - 1, with w the periodic Hann
                  window, 0.5 - 0.5 cos(2 pi t). The factor 2 / sum(w) makes a sine at f_k read
                  its own amplitude; librosa scales its atoms otherwise (L1, then sqrt(N_k)), so
                  its magnitudes differ from these by a factor per bin.

    transform     X[n, k] = sum_m x[n * hop + m] * conj(a_k[m]),  x = 0 outside the signal
                  (Brown 1991; librosa.cqt / librosa.vqt with center=True, pad_mode="constant")

    kernel        K[k, b] = conj(DFT_N(a_k laid in a frame of N points, centred on sample h))[b] / N
                  for b = 0 ... N/2, with N the smallest transform length (f * 2^n, f in 1, 3, 5,
                  15, n >= 4) that holds the longest atom of the octave and h half that atom
                  (Brown & Puckette 1992)

    chroma        bin k belongs to pitch class (c0 + round(12 k / B)) mod 12, c0 the class of the
                  semitone nearest to bin 0 with C as 0; the magnitudes of a class are summed and
                  the twelve sums divided by the largest (librosa.feature.chroma_cqt with
                  norm=inf, threshold=0; rounding of halves away from zero)

    pseudo CQ     C[n, k] = sum_b R_k[b] * |S[n, b]| for magnitudes, sum_b R_k[b]^2 * |S[n, b]|^2 for
                  powers, with S the STFT (causal frames, periodic Hann, no normalisation) and
                  R_k[b] = |DFT_M(a_k)[b]| / 2, the response of the atom, 1 at f_k
                  (librosa.pseudo_cqt, whose weights are scaled otherwise)

Tolerances, as the tests hold them: frequencies 1e-12 relative, atom lengths equal; dense kernel
entries 1e-6 of the largest entry of the row; the multirate transform within 0.03 of the frame
maximum of the definition (what a kernel thinned to sparsity 0.01 and half-band decimation
cost; the acceptance of section 6.8 is by property); chroma cosine similarity >= 0.98; the pseudo
constant-Q within 1e-5 of the frame maximum.

    python3 constant_q.py
"""
import math

import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()

TARGET = "ZTronDSPAnalysisTests"
cases = []


def note(midi):
    return 440.0 * 2.0 ** ((midi - 69.0) / 12.0)


def hann(t):
    return 0.5 - 0.5 * numpy.cos(2.0 * numpy.pi * t)


def frequencies(fmin, octaves, bins_per_octave, tuning):
    k = numpy.arange(octaves * bins_per_octave, dtype=numpy.float64)
    return fmin * 2.0 ** ((k + tuning) / bins_per_octave)


def exact_lengths(rate, freqs, bins_per_octave, filter_scale, gamma):
    alpha = 2.0 ** (1.0 / bins_per_octave) - 1.0
    return (filter_scale / alpha) * rate / (freqs + gamma / alpha)


def lengths(rate, freqs, bins_per_octave, filter_scale, gamma):
    exact = exact_lengths(rate, freqs, bins_per_octave, filter_scale, gamma)
    # A length within a millionth of a whole number would round either way in another arithmetic.
    if numpy.any(numpy.abs(exact - numpy.round(exact)) < 1e-6):
        raise ValueError("an atom length lies on a whole number: choose other parameters")
    return numpy.ceil(exact).astype(int)


def atom(length, cycles_per_sample):
    """(offsets m, samples a[m]) of the atom centred on offset 0."""
    m = numpy.arange(-(length // 2), (length + 1) // 2)
    w = hann(0.5 + m / float(length))
    return m, (2.0 / numpy.sum(w)) * w * numpy.exp(2j * numpy.pi * cycles_per_sample * m)


def transform(x, rate, freqs, atom_lengths, hop, frames):
    """The definition: frame n is centred on sample n * hop; the signal is zero outside itself."""
    x = numpy.asarray(x, dtype=numpy.float64)
    out = numpy.zeros((frames, len(freqs)), dtype=numpy.complex128)
    for k, (frequency, length) in enumerate(zip(freqs, atom_lengths)):
        m, a = atom(int(length), frequency / rate)
        conjugate = numpy.conj(a)
        for n in range(frames):
            index = n * hop + m
            inside = (index >= 0) & (index < len(x))
            out[n, k] = numpy.dot(x[index[inside]], conjugate[inside])
    return out


def next_fast_length(length):
    best = None
    for factor in (1, 3, 5, 15):
        candidate = factor * 16
        while candidate < length:
            candidate *= 2
        best = candidate if best is None else min(best, candidate)
    return best


def pitch_classes(first_frequency, bins_per_octave, count):
    first = int(math.floor(69.0 + 12.0 * math.log2(first_frequency / 440.0) + 0.5)) % 12
    return [(first + int(math.floor(12.0 * k / bins_per_octave + 0.5))) % 12 for k in range(count)]


def chroma(magnitudes, classes):
    sums = numpy.zeros((magnitudes.shape[0], 12))
    for k, pitch_class in enumerate(classes):
        sums[:, pitch_class] += magnitudes[:, k]
    largest = numpy.max(sums, axis=1)
    normalised = numpy.zeros_like(sums)
    loud = largest >= 1e-10
    normalised[loud] = sums[loud] / largest[loud, numpy.newaxis]
    return sums, normalised


# --- Geometry ----------------------------------------------------------------------------------------
GEOMETRIES = (
    # name, sample rate, fmin, octaves, bins per octave, tuning, filter scale, gamma
    ("defaults-48000", 48000.0, note(24), 7, 36, 0.0, 1.0, 0.0),
    ("defaults-44100", 44100.0, note(24), 7, 36, 0.0, 1.0, 0.0),
    ("defaults-22050", 22050.0, note(24), 7, 36, 0.0, 1.0, 0.0),
    ("semitones-tuned", 48000.0, 55.0, 8, 12, 0.25, 1.0, 0.0),
    ("quarter-tones-long", 44100.0, 27.5, 9, 24, -0.4, 2.0, 0.0),
    ("variable-q-short", 16000.0, note(36), 5, 12, 0.0, 0.5, 20.0),
    ("variable-q-fine", 48000.0, 110.0, 6, 48, 0.5, 1.0, 6.6),
)
for name, rate, fmin, octaves, bins, tuning, scale, gamma in GEOMETRIES:
    freqs = frequencies(fmin, octaves, bins, tuning)
    alpha = 2.0 ** (1.0 / bins) - 1.0
    cases.append(_golden.case(f"geometry-{name}", {
        "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning, "filterScale": scale,
        "gamma": gamma, "alpha": alpha, "q": scale / alpha},
        {"frequencies": _golden.real_vector(freqs),
         "atomLengths": _golden.real_vector(lengths(rate, freqs, bins, scale, gamma))}))

# --- The dense kernel of the highest octave ------------------------------------------------------------
KERNELS = (
    # name, sample rate, fmin, octaves, bins per octave, tuning, filter scale, gamma
    ("defaults-22050", 22050.0, note(24), 7, 36, 0.0, 1.0, 0.0),
    ("semitones-tuned", 16000.0, 110.0, 3, 12, 0.25, 1.0, 0.0),
    ("variable-q", 22050.0, note(36), 4, 24, 0.0, 1.0, 5.0),
)
for name, rate, fmin, octaves, bins, tuning, scale, gamma in KERNELS:
    freqs = frequencies(fmin, octaves, bins, tuning)[-bins:]
    atom_lengths = lengths(rate, freqs, bins, scale, gamma)
    span = int(atom_lengths.max())
    length = next_fast_length(span)
    centre = span // 2
    dense = numpy.zeros((bins, length // 2 + 1), dtype=numpy.complex128)
    energy = numpy.zeros(bins)
    for row in range(bins):
        m, a = atom(int(atom_lengths[row]), freqs[row] / rate)
        frame = numpy.zeros(length, dtype=numpy.complex128)
        frame[centre + m] = a
        spectrum = numpy.fft.fft(frame, n=length, axis=-1, norm="backward")
        dense[row] = numpy.conj(spectrum[:length // 2 + 1]) / length
        # The energy of the whole row, both halves of the spectrum.
        energy[row] = numpy.sum(numpy.abs(spectrum) ** 2) / length ** 2
    cases.append(_golden.case(f"kernel-{name}", {
        "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning, "filterScale": scale,
        "gamma": gamma, "span": span, "transformLength": length, "center": centre},
        {"real": _golden.raw_array(TARGET, f"constant_q_kernel_{name}_real.f64", dense.real, dtype="f64"),
         "imaginary": _golden.raw_array(TARGET, f"constant_q_kernel_{name}_imaginary.f64", dense.imag, dtype="f64"),
         "energy": _golden.real_vector(energy),
         "atomLengths": _golden.real_vector(atom_lengths)}))

# --- The transform of the fixtures, by its definition, and the chroma folded from it --------------------
TRANSFORMS = (
    # name, fixture, fmin, octaves, bins per octave, tuning, filter scale, gamma, hop
    ("music-defaults", "music", note(24), 7, 36, 0.0, 1.0, 0.0, 512),
    ("speech-semitones", "speech", note(36), 6, 12, 0.25, 1.0, 0.0, 256),
    ("music-variable-q", "music", note(24), 7, 24, 0.0, 1.0, 5.0, 512),
    ("music-top-octave", "music", note(84), 1, 36, 0.0, 1.0, 0.0, 128),
)
signals = {"music": _fixtures.music(numpy), "speech": _fixtures.speech(numpy)}
rate = _fixtures.SAMPLE_RATE
for name, fixture, fmin, octaves, bins, tuning, scale, gamma, hop in TRANSFORMS:
    samples = signals[fixture]
    freqs = frequencies(fmin, octaves, bins, tuning)
    atom_lengths = lengths(rate, freqs, bins, scale, gamma)
    # Every frame whose longest atom has seen its last sample: a stream gives no more, and a
    # streaming transform, which waits for its filters too, gives fewer.
    longest = int(atom_lengths.max())
    frames = (len(samples) - (longest + 1) // 2) // hop + 1
    spectrum = transform(samples, rate, freqs, atom_lengths, hop, frames)
    values = {
        "real": _golden.raw_array(TARGET, f"constant_q_{name}_real.f64", spectrum.real, dtype="f64"),
        "imaginary": _golden.raw_array(TARGET, f"constant_q_{name}_imaginary.f64", spectrum.imag, dtype="f64")}
    if bins % 12 == 0:
        sums, normalised = chroma(numpy.abs(spectrum), pitch_classes(freqs[0], bins, len(freqs)))
        values["chromaSums"] = _golden.raw_array(TARGET, f"constant_q_{name}_chroma_sums.f64", sums, dtype="f64")
        values["chroma"] = _golden.raw_array(TARGET, f"constant_q_{name}_chroma.f64", normalised, dtype="f64")
    cases.append(_golden.case(f"transform-{name}", {
        "fixture": fixture, "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning,
        "filterScale": scale, "gamma": gamma, "hop": hop, "frames": int(frames), "bins": int(len(freqs))}, values))

# --- The pseudo constant-Q of the fixtures ---------------------------------------------------------------
from scipy import signal  # noqa: E402

FRAME, HOP = 4096, 512
PSEUDO = (
    # name, fixture, fmin, octaves, bins per octave, tuning, filter scale, gamma
    ("music-semitones", "music", note(45), 6, 12, 0.0, 1.0, 0.0),
    ("speech-thirds-of-semitones", "speech", note(60), 4, 36, 0.0, 0.75, 0.0),
)
window = signal.get_window("hann", FRAME, fftbins=True)
for name, fixture, fmin, octaves, bins, tuning, scale, gamma in PSEUDO:
    samples = signals[fixture]
    freqs = frequencies(fmin, octaves, bins, tuning)
    atom_lengths = lengths(rate, freqs, bins, scale, gamma)
    if atom_lengths.max() > FRAME:
        raise ValueError("an atom is longer than the frame: the pseudo constant-Q does not resolve it")
    response = numpy.zeros((len(freqs), FRAME // 2 + 1))
    for k in range(len(freqs)):
        m, a = atom(int(atom_lengths[k]), freqs[k] / rate)
        frame = numpy.zeros(FRAME, dtype=numpy.complex128)
        frame[m - m[0]] = a
        # The transform of the atom is 2 at its own frequency: (2 / sum(w)) * sum(w).
        response[k] = numpy.abs(numpy.fft.fft(frame, n=FRAME, axis=-1, norm="backward")[:FRAME // 2 + 1]) / 2.0
    magnitudes = numpy.abs(_spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, False))
    cases.append(_golden.case(f"pseudo-{name}", {
        "fixture": fixture, "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning,
        "filterScale": scale, "gamma": gamma, "frame": FRAME, "hop": HOP, "frames": int(magnitudes.shape[0]), "bins": int(len(freqs))},
        {"magnitudes": _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_magnitudes.f64", magnitudes @ response.T, dtype="f64"),
         "powers": _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_powers.f64", (magnitudes ** 2) @ (response ** 2).T, dtype="f64"),
         "peakOfResponse": _golden.real_vector(numpy.max(response, axis=1))}))

_golden.write(TARGET, "constant_q", cases)
