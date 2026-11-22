"""The definitions of the onset strength and of the tempograms, written from their publications
with NumPy and SciPy (STG-2): the second, independent computation onset_strength.py and
tempogram.py hold librosa's output to (_golden.cross_check, within 1e-12) before they write it.
The vectors are librosa's (oracle form); each function states the definition it follows and the
librosa call it is held to.
"""


def next_fast_length(length):
    """The smallest f·2^n at or above `length`, f in 1, 3, 5, 15 and n >= 4: the transform
    lengths of the package (§6.4.1), as DSP.nextFastLength computes them."""
    if length <= 16:
        return 16
    best = None
    for factor in (1, 3, 5, 15):
        candidate = factor * 16
        while candidate < length:
            candidate *= 2
        best = candidate if best is None else min(best, candidate)
    return best


def power_to_decibels(numpy, power):
    """10·log10(max(p, 1e-16)): the package's conversion, a floor at -160 dB and nothing
    clipped relative to the maximum (not the defaults of librosa.power_to_db)."""
    return 10.0 * numpy.log10(numpy.maximum(numpy.asarray(power, dtype=numpy.float64), 1e-16))


def onset_strength(numpy, ndimage, decibels, lag, max_size, floor):
    """The onset strength of a spectrum in decibels, frames × bands (§6.9; Böck & Widmer 2013):

        o[t] = mean over bands f of max(0, S[f, t] - R[f, t - lag]),   0 for t < lag

    S is the spectrum with its values raised to `floor`; R is S, or S under a maximum filter of
    `max_size` bands along frequency. It is held to

        librosa.onset.onset_strength(y=None, sr=…, S=S.T, lag=lag, max_size=max_size, ref=None,
                                     detrend=False, center=False, feature=None,
                                     aggregate=numpy.mean)

    on a spectrum floored the same way: the reference is scipy.ndimage.maximum_filter1d with
    librosa's arguments, the difference is spaced by `lag`, negatives are discarded, the bands
    are averaged, and `lag` zeros lead the result in (center=False: no shift by half a frame,
    the frames here being stamped with their own times).
    """
    spectrum = numpy.maximum(numpy.asarray(decibels, dtype=numpy.float64), floor)
    if max_size == 1:
        reference = spectrum
    else:
        reference = ndimage.maximum_filter1d(spectrum, max_size, axis=1, mode="reflect", cval=0.0, origin=0)
    rise = numpy.maximum(0.0, spectrum[lag:] - reference[:-lag])
    return numpy.concatenate([numpy.zeros(lag), rise.mean(axis=1)])


def tempogram_windows(numpy, onset, window, centred):
    """The windows of a novelty curve a streaming tempogram sees, one per row.

    causal    window k is onset[k : k + window]: it describes the value it ends on
    centred   window k is centred on onset[k], which sits at index window // 2 of it; the curve
              is led in by a linear ramp from 0 (numpy.pad(mode="linear_ramp", end_values=0),
              as librosa.feature.tempogram(center=True) pads it; tempogram.py frames librosa's
              way and asserts the same windows through the cross-check)

    A stream has no end: of the centred windows only those whose last value has arrived exist.
    """
    y = numpy.asarray(onset, dtype=numpy.float64)
    if centred:
        lead = window // 2
        y = numpy.concatenate([numpy.linspace(0.0, y[0], lead, endpoint=False), y])
    count = len(y) - window + 1
    return numpy.stack([y[k:k + window] for k in range(count)])


def autocorrelation_tempogram(numpy, windows, taper, feature_rate, low, high, floor):
    """The autocorrelation tempogram (§6.9; Grosche, Müller & Kurth 2010): each window has its
    mean removed, is tapered, autocorrelated (the linear autocorrelation, by its definition) and
    divided by its value at lag 0; a window whose value at lag 0 does not exceed `floor` is zeros.
    Lag l is 60·feature_rate / l beats per minute. The rows are the lags inside low … high, in
    ascending tempo. Returns (columns, beats per minute).

    librosa.feature.tempogram differs in two documented ways: it does not remove the mean, and it
    returns every lag. tempogram.py therefore holds this to librosa.feature.tempogram called on
    each mean-removed window (center=False, norm=None), normalised by librosa.util.normalize
    (norm=inf, threshold=floor, fill=False), the rows of these lags kept.
    """
    window = windows.shape[1]
    segments = (windows - windows.mean(axis=1, keepdims=True)) * numpy.asarray(taper, dtype=numpy.float64)[numpy.newaxis, :]
    lags = [lag for lag in range(window - 1, 0, -1) if low <= 60.0 * feature_rate / lag <= high]
    columns = numpy.zeros((len(segments), len(lags)))
    for index, segment in enumerate(segments):
        full = numpy.correlate(segment, segment, mode="full")[window - 1:]
        if full[0] > floor:
            columns[index] = full[lags] / full[0]
    return columns, [60.0 * feature_rate / lag for lag in lags]


def fourier_tempogram(numpy, windows, taper, feature_rate, low, high, resolution):
    """The Fourier tempogram (§6.9; Grosche & Müller 2011): the magnitude of the DFT of each
    window, mean removed and tapered, zero-padded to the fast length at or above
    resolution·window. Bin k is 60·k·feature_rate / length beats per minute; the rows are the
    bins inside low … high. Returns (columns, beats per minute).

    librosa.feature.fourier_tempogram differs: it keeps the mean, does not zero-pad, returns the
    complex spectrum, and leads a centred curve in with zeros. tempogram.py therefore holds this
    to the magnitude of librosa.feature.fourier_tempogram called on each mean-removed window
    zero-padded to the fast length (center=False, the taper zero-padded alike), the rows of
    these bins kept.
    """
    window = windows.shape[1]
    segments = (windows - windows.mean(axis=1, keepdims=True)) * numpy.asarray(taper, dtype=numpy.float64)[numpy.newaxis, :]
    length = next_fast_length(resolution * window)
    spacing = 60.0 * feature_rate / length
    bins = [k for k in range(1, length // 2 + 1) if low <= k * spacing <= high]
    spectrum = numpy.abs(numpy.fft.rfft(segments, n=length, axis=1, norm="backward"))
    return spectrum[:, bins], [k * spacing for k in bins]
