"""Reference implementations the spectral generators share, written from the published
definitions with NumPy only (STG-2). librosa, which the table of STG-2 names for several of
them, is not installed where the vectors were generated; each function states the definition
it follows and the librosa call it stands for.
"""


def frames(numpy, x, frame, hop, centred):
    """The frames a streaming analysis of `x` produces, one per row, in double precision.

    causal    frame k is x[k·hop : k·hop + frame]                        (librosa: center=False)
    centred   frame k is centred on x[k·hop]; the signal is reflected    (librosa: center=True,
              at its start, the edge sample not repeated                  pad_mode="reflect")

    A stream has no end, so of the centred frames only those whose last sample has arrived exist.
    """
    y = numpy.asarray(x, dtype=numpy.float64)
    if centred:
        y = numpy.pad(y, (frame // 2, 0), mode="reflect")
        count = (len(x) - frame // 2) // hop + 1
    else:
        count = (len(x) - frame) // hop + 1
    return numpy.stack([y[k * hop:k * hop + frame] for k in range(count)])


def stft(numpy, x, frame, hop, window, length, centred, factor=1.0):
    """X[k, m] = Σ_n factor·w[n]·y[k·hop + n]·e^(−j2πmn/length): the unscaled one-sided DFT of
    each windowed frame, zero-padded after its samples to `length` (librosa.stft with
    win_length == n_fft when length == frame)."""
    cut = frames(numpy, x, frame, hop, centred) * numpy.asarray(window)[numpy.newaxis, :] * factor
    return numpy.fft.rfft(cut, n=length, axis=-1, norm="backward")


def hz_to_mel(numpy, hertz, htk):
    """Slaney (Auditory Toolbox): 3f/200 below 1 kHz, 15 + 27·ln(f/1000)/ln(6.4) from there on.
    HTK: 2595·log10(1 + f/700). (librosa.hz_to_mel)"""
    f = numpy.asarray(hertz, dtype=numpy.float64)
    if htk:
        return 2595.0 * numpy.log10(1.0 + f / 700.0)
    linear = 3.0 * f / 200.0
    logarithmic = 15.0 + 27.0 * numpy.log(numpy.maximum(f, 1e-300) / 1000.0) / numpy.log(6.4)
    return numpy.where(f < 1000.0, linear, logarithmic)


def mel_to_hz(numpy, mel, htk):
    """The inverse of hz_to_mel. (librosa.mel_to_hz)"""
    m = numpy.asarray(mel, dtype=numpy.float64)
    if htk:
        return 700.0 * (10.0 ** (m / 2595.0) - 1.0)
    return numpy.where(m < 15.0, 200.0 * m / 3.0, 1000.0 * numpy.exp(numpy.log(6.4) / 27.0 * (m - 15.0)))


def mel_filter_bank(numpy, sample_rate, length, bands, fmin, fmax, htk, slaney_norm):
    """The triangular mel filter bank, bands × (length/2 + 1), in double precision
    (librosa.filters.mel with norm="slaney" or norm=None).

    bands + 2 edges are equally spaced on the mel scale from fmin to fmax. Band i rises linearly
    in hertz from edge i to edge i + 1 and falls to edge i + 2, evaluated at the bin centres
    k·sample_rate/length; Slaney's normalisation scales it by 2 / (edge i+2 − edge i).
    """
    bins = numpy.arange(length // 2 + 1, dtype=numpy.float64) * sample_rate / length
    edges = mel_to_hz(numpy, numpy.linspace(hz_to_mel(numpy, fmin, htk), hz_to_mel(numpy, fmax, htk), bands + 2, endpoint=True), htk)
    weights = numpy.zeros((bands, len(bins)))
    for i in range(bands):
        rising = (bins - edges[i]) / (edges[i + 1] - edges[i])
        falling = (edges[i + 2] - bins) / (edges[i + 2] - edges[i + 1])
        weights[i] = numpy.maximum(0.0, numpy.minimum(rising, falling))
        if slaney_norm:
            weights[i] *= 2.0 / (edges[i + 2] - edges[i])
    return weights, edges


def window_figures_exact(numpy, optimize, w):
    """The spectral figures of a window from its transform evaluated wherever it is needed
    (Harris 1978): the figures themselves, not an approximation on a grid.

        P(f) = |Σ_n w[n]·e^(−j2πfn/N)|²,  f in bins of the N-point transform

    Returns (half-power width, null-to-null width, peak side lobe in dB, scalloping loss in dB,
    fall-off in dB per octave or None). The fall-off is the least-squares line through the
    side-lobe peaks between N/32 (and never below 8) and N/4 bins against log2 of their
    frequency, when at least three lie there.
    """
    w = numpy.asarray(w, dtype=numpy.float64)
    count = len(w)
    n = numpy.arange(count)

    def power(f):
        return float(numpy.abs(numpy.sum(w * numpy.exp(-2j * numpy.pi * f * n / count))) ** 2)

    reference = power(0.0)

    def level(f):
        return 10.0 * numpy.log10(max(power(f) / reference, 1e-40))

    # A fine grid to find where to look: 64 points per bin, up to the Nyquist bin.
    pad = 64
    grid = numpy.abs(numpy.fft.rfft(w, n=pad * count, axis=-1, norm="backward")) ** 2 / reference
    step = 1.0 / pad

    below = int(numpy.argmax(grid <= 0.5))
    half = optimize.brentq(lambda f: power(f) / reference - 0.5, (below - 1) * step, below * step, xtol=1e-13, rtol=1e-13, maxiter=200)

    null = None
    for k in range(1, len(grid) - 1):
        if grid[k] < grid[k - 1] and grid[k] <= grid[k + 1]:
            null = k
            break
    null_frequency = None
    lobes = []
    if null is not None:
        found = optimize.minimize_scalar(power, bounds=((null - 1) * step, (null + 1) * step), method="bounded",
                                         options={"xatol": 1e-12, "maxiter": 500})
        null_frequency = float(found.x)
        decibels = 10.0 * numpy.log10(numpy.maximum(grid, 1e-40))
        candidates = [k for k in range(null + 1, len(grid) - 1) if decibels[k] >= decibels[k - 1] and decibels[k] > decibels[k + 1]]
        # Refine the lobes the figures are read from: those up to N/4 bins, and the highest ones.
        highest = sorted(candidates, key=lambda k: -decibels[k])[:4]
        for k in candidates:
            if k * step <= count / 4.0 + 1.0 or k in highest:
                found = optimize.minimize_scalar(lambda f: -level(f), bounds=((k - 1) * step, (k + 1) * step), method="bounded",
                                                 options={"xatol": 1e-12, "maxiter": 500})
                lobes.append((float(found.x), -float(found.fun)))
    peak_side_lobe = max(l for _, l in lobes) if lobes else None
    fitted = [(f, l) for f, l in lobes if max(count / 32.0, 8.0) <= f <= count / 4.0 and l > -380.0]
    fall_off = None
    if len(fitted) >= 3:
        octaves = numpy.log2([f for f, _ in fitted])
        levels = numpy.array([l for _, l in fitted])
        fall_off = float(numpy.sum((octaves - octaves.mean()) * (levels - levels.mean())) / numpy.sum((octaves - octaves.mean()) ** 2))
    return 2.0 * half, (2.0 * null_frequency if null_frequency is not None else None), peak_side_lobe, -level(0.5), fall_off


def window_figures_on_grid(numpy, w):
    """The same figures the way the package measures them (WindowAnalysis): on the transform of
    the window zero-padded sixteen times, with the main lobe interpolated linearly in decibels,
    the first null as the zero of the line between two points of the transform, each side lobe
    by a parabola through three powers. Returns (decibels, bin step, half-power width,
    null-to-null width or None, peak side lobe or None, fall-off or None, scalloping loss)."""
    w = numpy.asarray(w, dtype=numpy.float64)
    count = len(w)
    length = 16 * count
    spectrum = numpy.fft.rfft(w, n=length, axis=-1, norm="backward")
    power = spectrum.real ** 2 + spectrum.imag ** 2
    reference = power[0] if power[0] > 0 else max(power.max(), 1e-300)
    power = numpy.maximum(power / reference, 1e-40)
    step = count / length
    decibels = 10.0 * numpy.log10(power)
    last = len(power) - 1

    half_width = 2.0 * last * step
    below = int(numpy.argmax(power <= 0.5))
    if power[below] <= 0.5 and below > 0:
        above, under, target = decibels[below - 1], decibels[below], 10.0 * numpy.log10(0.5)
        fraction = (above - target) / (above - under) if above > under else 0.0
        half_width = 2.0 * ((below - 1) + fraction) * step

    null = None
    for k in range(1, last):
        if power[k] < power[k - 1] and power[k] <= power[k + 1]:
            null = k
            break
    null_width = None
    lobes = []
    if null is not None:
        best = (float(null), numpy.inf)
        for start in (null - 1, null):
            d = spectrum[start + 1] - spectrum[start]
            size = d.real ** 2 + d.imag ** 2
            fraction = min(max(-(spectrum[start].real * d.real + spectrum[start].imag * d.imag) / size, 0.0), 1.0) if size > 0 else 0.0
            at = spectrum[start] + fraction * d
            residual = at.real ** 2 + at.imag ** 2
            if residual < best[1]:
                best = (start + fraction, residual)
        null_width = 2.0 * best[0] * step
        for k in range(null + 1, last):
            if power[k] >= power[k - 1] and power[k] > power[k + 1]:
                curvature = power[k - 1] - 2.0 * power[k] + power[k + 1]
                shift, top = 0.0, power[k]
                if curvature < 0:
                    shift = min(max(0.5 * (power[k - 1] - power[k + 1]) / curvature, -0.5), 0.5)
                    top -= 0.25 * (power[k - 1] - power[k + 1]) * shift
                lobes.append(((k + shift) * step, 10.0 * numpy.log10(max(top, 1e-40))))
    peak_side_lobe = max(l for _, l in lobes) if lobes else None
    fitted = [(f, l) for f, l in lobes if max(count / 32.0, 8.0) <= f <= count / 4.0 and l > 10.0 * numpy.log10(1e-40) + 20.0]
    fall_off = None
    if len(fitted) >= 3:
        octaves = numpy.log2([f for f, _ in fitted])
        levels = numpy.array([l for _, l in fitted])
        spread = numpy.sum((octaves - octaves.mean()) ** 2)
        if spread > 0:
            fall_off = float(numpy.sum((octaves - octaves.mean()) * (levels - levels.mean())) / spread)
    half = 0.5 / step
    lower = min(int(numpy.floor(half)), last)
    upper = min(lower + 1, last)
    fraction = half - lower
    scalloping = -(decibels[lower] * (1.0 - fraction) + decibels[upper] * fraction)
    return decibels, step, half_width, null_width, peak_side_lobe, fall_off, float(scalloping)
