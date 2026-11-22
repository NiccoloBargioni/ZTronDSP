"""Golden vectors for the constant-Q transform and chroma (WP-517 … WP-524, STG-2).

The definitions of §6.8 are evaluated here directly, densely and in double precision with NumPy;
nothing of the method under test (octave recursion, half-band decimation, sparse kernels) is used.
librosa 0.11.0 is the oracle wherever the specification's quantity and a librosa call are the
same function (ORACLE FORM: librosa's output is written, held first to the definition within
1e-12), and where they are not, librosa's output is written beside the definition's and compared
by the specification's criterion (DERIVED FORM). Every librosa argument is explicit, the input
is float64.

    geometry      f_k = fmin * 2^((k + tuning) / B),  alpha = 2^(1/B) - 1,  Q = filterScale / alpha,
                  N_k = ceil(Q * fs / (f_k + gamma / alpha))                          (section 6.8)
                  ORACLE FORM: librosa.cqt_frequencies(n_bins=octaves * B, fmin=fmin,
                  bins_per_octave=B, tuning=tuning), and the ceiling of
                  librosa.filters.wavelet_lengths(freqs=f, sr=fs, window="hann",
                  filter_scale=filterScale, gamma=gamma, alpha=2^(1/B) - 1 for every bin)[0]
                  (alpha given: librosa's own default is its relative bandwidth,
                  (2^(2/B) - 1) / (2^(2/B) + 1), whose atoms are 1 to 3 % longer)

    atom          a_k[m] = (2 / sum(w)) * w(1/2 + m / N_k) * exp(j 2 pi f_k m / fs)
                  for m = -floor(N_k / 2) ... ceil(N_k / 2) - 1, with w the periodic Hann
                  window, 0.5 - 0.5 cos(2 pi t). The factor 2 / sum(w) makes a sine at f_k read
                  its own amplitude; librosa scales its atoms otherwise (L1, then by N_k / n_fft,
                  then the response by 1 / sqrt(N_k)), builds them of 2 floor(N_k / 2) + 1 samples
                  and resamples between octaves, so no factor per bin turns its transform into
                  this one.

    kernel        K[k, b] = conj(DFT_N(a_k laid in a frame of N points, centred on sample h))[b] / N
                  for b = 0 ... N/2, with N the smallest transform length (f * 2^n, f in 1, 3, 5,
                  15, n >= 4) that holds the longest atom of the octave and h half that atom
                  (Brown & Puckette 1992). The definition only: no librosa function returns the
                  spectral kernel of these atoms (librosa.filters.constant_q builds librosa's).

    transform     X[n, k] = sum_m x[n * hop + m] * conj(a_k[m]),  x = 0 outside the signal
                  (Brown 1991). DERIVED FORM: the definition's X is the tested vector; beside
                  it, librosa's chroma of librosa's transform,
                      librosa.feature.chroma_cqt(y=None, sr=22050.0, C=numpy.abs(V), hop_length=hop,
                          fmin=fmin * 2^(tuning / B), norm=numpy.inf, threshold=0.0, tuning=tuning,
                          n_chroma=12, n_octaves=octaves, window=None, bins_per_octave=B,
                          cqt_mode="full")
                      V = librosa.cqt(y=x, sr=22050.0, hop_length=hop, fmin=fmin, n_bins=octaves * B,
                          bins_per_octave=B, tuning=tuning, filter_scale=filterScale, norm=1,
                          sparsity=0.01, window="hann", scale=True, pad_mode="constant",
                          res_type="soxr_hq", dtype=numpy.complex128)
                      (librosa.vqt with intervals="equal" and gamma=gamma, the same otherwise,
                      for gamma > 0; 22 050 Hz is the fixtures' rate), the frames centred on
                      n * hop as the definition's
                  which ChromaTests holds the package's chroma to by the criterion of section 6.8:
                  frame-wise cosine similarity >= 0.98 on the music fixtures.

    chroma        bin k belongs to pitch class (c0 + round(12 k / B)) mod 12, c0 the class of the
                  semitone nearest to bin 0 with C as 0; the magnitudes of a class are summed and
                  the twelve sums divided by the largest. ORACLE FORM for the fold: what is
                  written is librosa.feature.chroma_cqt (arguments as above, norm=numpy.inf, and
                  norm=None for the sums) of the definition's magnitudes, held to the fold of the
                  definition within 1e-12.

    pseudo CQ     C[n, k] = sum_b R_k[b] * |S[n, b]| for magnitudes, sum_b R_k[b]^2 * |S[n, b]|^2 for
                  powers, with S the STFT (causal frames, periodic Hann, no normalisation) and
                  R_k[b] = |DFT_M(a_k)[b]| / 2, the response of the atom, 1 at f_k. S is librosa's
                  (librosa.stft, center=False, held to the definition within 1e-12). DERIVED FORM:
                  the definition's C is the tested vector; beside it, librosa's chroma of
                      P = librosa.pseudo_cqt(y=x, sr=22050.0, hop_length=512, fmin=fmin,
                          n_bins=octaves * B, bins_per_octave=B, tuning=tuning,
                          filter_scale=filterScale, norm=1, sparsity=0.01, window="hann",
                          scale=True, pad_mode="constant", dtype=numpy.complex128)
                  in its frames centred on the centres of the definition's (four frames later),
                  twice: of |P| as it is ("librosaChromaAsIs"), and of |P| with librosa's scale of
                  band k, l_k / n_fft^(3/2), removed ("librosaChroma"), l_k the lengths librosa
                  builds the atoms with, librosa.filters.wavelet_lengths with librosa's relative
                  bandwidth. librosa's scale weighs the low octaves by 1/f in the fold, so the
                  first cannot meet 0.98 against chroma whose bands read their own amplitude
                  (it measures 0.963 on the music fixture): CR-035 proposes the second as the
                  reference of section 6.8 for the pseudo constant-Q.

The cosine of the definition's chroma against librosa's is printed for every case (a
"cross-check" line of the run log) and must reach 0.98 on the music fixtures, or the generator
stops; on the speech fixture it is recorded only.

Read by ZTronDSPAnalysisTests (ConstantQGeometryTests, ConstantQKernelTests, ConstantQTests,
ChromaTests, ConstantQScaleTests). Tolerances, as the tests hold them: frequencies 1e-12
relative, atom lengths equal; dense kernel entries 1e-6 of the largest entry of the row; the
multirate transform within 0.03 of the frame maximum of the definition (what a kernel thinned to
sparsity 0.01 and half-band decimation cost; the acceptance of section 6.8 is by property);
chroma cosine similarity >= 0.98; the pseudo constant-Q within 1e-5 of the frame maximum.

    python3 constant_q.py
"""
import math

import _golden
import _fixtures
import _spectral

numpy, scipy = _golden.oracle()
librosa = _golden.librosa()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
MUSIC_CRITERION = 0.98
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


def librosa_chroma(magnitudes, hop, fmin, octaves, bins, tuning, norm):
    """librosa.feature.chroma_cqt of constant-Q magnitudes, frames × bins in and frames × 12 out;
    fmin is the centre of bin 0 before tuning, as the transform was given it."""
    return librosa.feature.chroma_cqt(y=None, sr=_fixtures.SAMPLE_RATE, C=numpy.ascontiguousarray(magnitudes.T), hop_length=hop,
                                      fmin=fmin * 2.0 ** (tuning / bins), norm=norm, threshold=0.0, tuning=tuning, n_chroma=12,
                                      n_octaves=octaves, window=None, bins_per_octave=bins, cqt_mode="full").T


def least_cosine(a, b):
    """The least frame-wise cosine similarity of two chroma sequences, frames × 12 (a frame of
    zeros against a frame of zeros counts as 1, against anything else as 0)."""
    least = 1.0
    for x, y in zip(a, b):
        nx, ny = numpy.linalg.norm(x), numpy.linalg.norm(y)
        value = float(numpy.dot(x, y) / (nx * ny)) if nx > 0 and ny > 0 else (1.0 if nx == ny else 0.0)
        least = min(least, value)
    return least


def compare_chroma(what, fixture, definition, reference):
    """Prints the least frame-wise cosine of the definition's chroma against librosa's; on a music
    fixture it must reach the criterion of §6.8."""
    least = least_cosine(definition, reference)
    if fixture == "music":
        print(f"cross-check {what}: least frame-wise cosine of the definition's chroma {least:.4f} (criterion >= {MUSIC_CRITERION}, §6.8)")
        if least < MUSIC_CRITERION:
            raise SystemExit(f"{what}: the definition's chroma meets librosa's at {least:.4f} only: settle that first")
    else:
        print(f"cross-check {what}: least frame-wise cosine of the definition's chroma {least:.4f} (a speech fixture: recorded, no criterion)")
    return least


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
    alpha = 2.0 ** (1.0 / bins) - 1.0
    freqs = librosa.cqt_frequencies(n_bins=octaves * bins, fmin=fmin, bins_per_octave=bins, tuning=tuning)
    exact, _ = librosa.filters.wavelet_lengths(freqs=freqs, sr=rate, window="hann", filter_scale=scale, gamma=gamma,
                                               alpha=numpy.full(len(freqs), alpha))
    if numpy.any(numpy.abs(exact - numpy.round(exact)) < 1e-6):
        raise ValueError(f"geometry {name}: an atom length lies on a whole number: choose other parameters")
    atom_lengths = numpy.ceil(exact).astype(int)
    definition = frequencies(fmin, octaves, bins, tuning)
    _golden.cross_check(f"cqt_frequencies {name}", freqs, definition, 1e-12)
    _golden.cross_check(f"wavelet_lengths {name}", exact, exact_lengths(rate, definition, bins, scale, gamma), 1e-12)
    _golden.cross_check(f"atom lengths {name}", atom_lengths, lengths(rate, definition, bins, scale, gamma), 0.0)
    cases.append(_golden.case(f"geometry-{name}", {
        "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning, "filterScale": scale,
        "gamma": gamma, "alpha": alpha, "q": scale / alpha},
        {"frequencies": _golden.real_vector(freqs), "atomLengths": _golden.real_vector(atom_lengths)}))

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
        magnitudes = numpy.abs(spectrum)
        sums = librosa_chroma(magnitudes, hop, fmin, octaves, bins, tuning, None)
        normalised = librosa_chroma(magnitudes, hop, fmin, octaves, bins, tuning, numpy.inf)
        definition_sums, definition_normalised = chroma(magnitudes, pitch_classes(freqs[0], bins, len(freqs)))
        _golden.cross_check(f"chroma_cqt fold, sums, {name}", sums, definition_sums, 1e-12)
        _golden.cross_check(f"chroma_cqt fold, normalised, {name}", normalised, definition_normalised, 1e-12)
        y = numpy.asarray(samples, dtype=numpy.float64)
        if gamma == 0:
            response = librosa.cqt(y=y, sr=rate, hop_length=hop, fmin=fmin, n_bins=octaves * bins, bins_per_octave=bins, tuning=tuning,
                                   filter_scale=scale, norm=1, sparsity=0.01, window="hann", scale=True, pad_mode="constant",
                                   res_type="soxr_hq", dtype=numpy.complex128)
        else:
            response = librosa.vqt(y=y, sr=rate, hop_length=hop, fmin=fmin, n_bins=octaves * bins, intervals="equal", gamma=gamma,
                                   bins_per_octave=bins, tuning=tuning, filter_scale=scale, norm=1, sparsity=0.01, window="hann",
                                   scale=True, pad_mode="constant", res_type="soxr_hq", dtype=numpy.complex128)
        if response.shape[1] < frames:
            raise SystemExit(f"transform {name}: librosa gives {response.shape[1]} frames, the definition {frames}")
        reference = librosa_chroma(numpy.abs(response.T[:frames]), hop, fmin, octaves, bins, tuning, numpy.inf)
        compare_chroma(f"transform-{name} chroma against librosa.chroma_cqt(|librosa.{'cqt' if gamma == 0 else 'vqt'}|)", fixture,
                       normalised, reference)
        values["chromaSums"] = _golden.raw_array(TARGET, f"constant_q_{name}_chroma_sums.f64", sums, dtype="f64")
        values["chroma"] = _golden.raw_array(TARGET, f"constant_q_{name}_chroma.f64", normalised, dtype="f64")
        values["librosaChroma"] = _golden.raw_array(TARGET, f"constant_q_{name}_librosa_chroma.f64", reference, dtype="f64")
    cases.append(_golden.case(f"transform-{name}", {
        "fixture": fixture, "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning,
        "filterScale": scale, "gamma": gamma, "hop": hop, "frames": int(frames), "bins": int(len(freqs))}, values))

# --- The pseudo constant-Q of the fixtures ---------------------------------------------------------------
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
    y = numpy.asarray(samples, dtype=numpy.float64)
    spectrum = librosa.stft(y=y, n_fft=FRAME, hop_length=HOP, win_length=FRAME, window="hann", center=False,
                            dtype=numpy.complex128, pad_mode="reflect", out=None).T
    _golden.cross_check(f"stft pseudo-{name}", spectrum, _spectral.stft(numpy, samples, FRAME, HOP, window, FRAME, False), 1e-12)
    magnitudes = numpy.abs(spectrum)
    projected = magnitudes @ response.T
    values = {
        "magnitudes": _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_magnitudes.f64", projected, dtype="f64"),
        "powers": _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_powers.f64", (magnitudes ** 2) @ (response ** 2).T, dtype="f64"),
        "peakOfResponse": _golden.real_vector(numpy.max(response, axis=1))}
    if bins % 12 == 0:
        pseudo = numpy.abs(librosa.pseudo_cqt(y=y, sr=rate, hop_length=HOP, fmin=fmin, n_bins=octaves * bins, bins_per_octave=bins,
                                              tuning=tuning, filter_scale=scale, norm=1, sparsity=0.01, window="hann", scale=True,
                                              pad_mode="constant", dtype=numpy.complex128))
        # The lengths librosa builds the atoms of pseudo_cqt with: its relative bandwidth.
        ratio = 2.0 ** (1.0 / bins)
        relative_bandwidth = (ratio ** 2 - 1.0) / (ratio ** 2 + 1.0)
        built, _ = librosa.filters.wavelet_lengths(
            freqs=librosa.cqt_frequencies(n_bins=octaves * bins, fmin=fmin * 2.0 ** (tuning / bins), bins_per_octave=bins, tuning=0.0),
            sr=rate, window="hann", filter_scale=scale, gamma=0.0, alpha=numpy.full(octaves * bins, relative_bandwidth))
        offset = FRAME // (2 * HOP)
        count = projected.shape[0]
        if pseudo.shape[1] < offset + count:
            raise SystemExit(f"pseudo-{name}: librosa gives {pseudo.shape[1]} frames, {offset + count} are needed")
        aligned = pseudo.T[offset:offset + count]
        as_is = librosa_chroma(aligned, HOP, fmin, octaves, bins, tuning, numpy.inf)
        unscaled = librosa_chroma(aligned * (FRAME ** 1.5 / built)[numpy.newaxis, :], HOP, fmin, octaves, bins, tuning, numpy.inf)
        definition = librosa_chroma(projected, HOP, fmin, octaves, bins, tuning, numpy.inf)
        _golden.cross_check(f"chroma_cqt fold, pseudo-{name}", definition, chroma(projected, pitch_classes(freqs[0], bins, len(freqs)))[1], 1e-12)
        least_cosine_as_is = least_cosine(definition, as_is)
        print(f"cross-check pseudo-{name} chroma against librosa.chroma_cqt(|librosa.pseudo_cqt|) as it is: least frame-wise cosine "
              f"{least_cosine_as_is:.4f} (librosa's scale of band k, l_k / n_fft^1.5, kept: CR-035)")
        compare_chroma(f"pseudo-{name} chroma against librosa.chroma_cqt(|librosa.pseudo_cqt| * n_fft^1.5 / l_k)", fixture, definition, unscaled)
        values["librosaChroma"] = _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_librosa_chroma.f64", unscaled, dtype="f64")
        values["librosaChromaAsIs"] = _golden.raw_array(TARGET, f"constant_q_pseudo_{name}_librosa_chroma_as_is.f64", as_is, dtype="f64")
    cases.append(_golden.case(f"pseudo-{name}", {
        "fixture": fixture, "sampleRate": rate, "fmin": fmin, "octaves": octaves, "binsPerOctave": bins, "tuning": tuning,
        "filterScale": scale, "gamma": gamma, "frame": FRAME, "hop": HOP, "frames": int(magnitudes.shape[0]), "bins": int(len(freqs))},
        values))

_golden.write(TARGET, "constant_q", cases)
