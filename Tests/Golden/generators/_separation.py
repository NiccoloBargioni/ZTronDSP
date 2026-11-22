"""The definition of the harmonic–percussive separation, written from its publication with NumPy
and SciPy (STG-2): the second, independent computation hpss.py holds librosa's masks to
(_golden.cross_check, within 1e-12) before it writes them. The vectors are librosa's
(librosa.decompose.hpss, oracle form); each function states the definition it follows and the
librosa call it is held to.
"""


def medians(ndimage, magnitudes, time_kernel, frequency_kernel):
    """The two medians of a magnitude spectrogram, frames × bins (Fitzgerald 2010): along time
    over `time_kernel` frames and along frequency over `frequency_kernel` bins, the edges
    reflected with the edge value repeated. These are the two calls of librosa.decompose.hpss,

        scipy.ndimage.median_filter(S, size=(1, win_harm), mode="reflect")     # S there is bins × frames
        scipy.ndimage.median_filter(S, size=(win_perc, 1), mode="reflect")

    with the axes of this spectrogram. Returns (harmonic, percussive).
    """
    harmonic = ndimage.median_filter(magnitudes, size=(time_kernel, 1), mode="reflect", cval=0.0, origin=0)
    percussive = ndimage.median_filter(magnitudes, size=(1, frequency_kernel), mode="reflect", cval=0.0, origin=0)
    return harmonic, percussive


def soft_mask(numpy, component, competitor, power, floor):
    """M = c^p / (c^p + k^p), computed on the two values divided by the larger of them, as
    librosa.util.softmask(X, X_ref, power=power, split_zeros=…) computes it, with one
    difference the specification asks for (§6.10, NUM-1): where the larger of the two lies
    below `floor` the mask is 0, where librosa uses the smallest normal number (and 0.5 when
    split_zeros, which librosa.decompose.hpss sets at unit margins)."""
    larger = numpy.maximum(component, competitor)
    known = larger >= floor
    scale = numpy.where(known, larger, 1.0)
    own = (component / scale) ** power
    other = (competitor / scale) ** power
    return numpy.where(known, own / numpy.where(known, own + other, 1.0), 0.0)


def hard_mask(numpy, component, competitor, floor):
    """The limit of the soft mask (librosa.util.softmask with power=inf): 1 where the component
    exceeds the competitor, 0 elsewhere; 0 where neither reaches `floor`."""
    return numpy.where((component > competitor) & (numpy.maximum(component, competitor) >= floor), 1.0, 0.0)


def masks(numpy, harmonic, percussive, power, harmonic_margin, percussive_margin, floor):
    """The harmonic and the percussive mask, as librosa.decompose.hpss forms them:

        mask_harm = softmask(harm, perc · margin_harm, power)
        mask_perc = softmask(perc, harm · margin_perc, power)

    `power` None is the hard mask. Returns (harmonic mask, percussive mask)."""
    if power is None:
        return (hard_mask(numpy, harmonic, percussive * harmonic_margin, floor),
                hard_mask(numpy, percussive, harmonic * percussive_margin, floor))
    return (soft_mask(numpy, harmonic, percussive * harmonic_margin, power, floor),
            soft_mask(numpy, percussive, harmonic * percussive_margin, power, floor))
