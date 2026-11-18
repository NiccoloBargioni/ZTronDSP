"""The speech and music fixtures of the spectral golden vectors (STG-2).

The specification names "the speech and music fixtures" without supplying recordings, so these
are synthetic and deterministic: the same arrays on every run, built with NumPy from explicit
seeds. `fixtures.py` writes them where the tests read them; the generators that need them call
the functions here and get the same samples.

    speech(numpy)   1.0 s at 22 050 Hz: a voiced source whose pitch glides from 110 to 150 Hz,
                    harmonics falling off as 1/k, shaped by three formant resonators, with a
                    little noise, and two short pauses.
    music(numpy)    2.0 s at 22 050 Hz: four plucked chords (harmonic partials with exponential
                    decay) over a click at 120 beats per minute, on a noise floor.

Both carry broadband noise, as a recording does. A spectrum that is empty to the last bit would
put most of its bins below the round-off floor of a single-precision transform (about 8e-8 of
the frame maximum, §6.1), and a logarithm taken there measures that round-off, not the feature:
the references are double precision and would differ from any single-precision analysis by tens
of decibels in bins that hold nothing.
"""

SAMPLE_RATE = 22050.0


def speech(numpy):
    from scipy import signal
    rate = SAMPLE_RATE
    count = int(rate)
    t = numpy.arange(count) / rate
    pitch = 110.0 + 40.0 * t
    phase = 2.0 * numpy.pi * numpy.cumsum(pitch) / rate
    source = numpy.zeros(count)
    for harmonic in range(1, 40):
        source += numpy.sin(harmonic * phase) / harmonic
    rng = numpy.random.default_rng(20261115)
    source += 0.02 * rng.standard_normal(count)
    voiced = source
    for centre, width in ((700.0, 110.0), (1220.0, 140.0), (2600.0, 200.0)):
        radius = numpy.exp(-numpy.pi * width / rate)
        angle = 2.0 * numpy.pi * centre / rate
        b = [1.0 - radius]
        a = [1.0, -2.0 * radius * numpy.cos(angle), radius * radius]
        voiced = voiced + 4.0 * signal.lfilter(b, a, source, axis=-1, zi=None)
    # Two pauses: 0.30–0.36 s and 0.70–0.74 s, with 5 ms ramps.
    gate = numpy.ones(count)
    ramp = int(0.005 * rate)
    for start, stop in ((0.30, 0.36), (0.70, 0.74)):
        a, b = int(start * rate), int(stop * rate)
        gate[a:b] = 0.0
        gate[a - ramp:a] = numpy.linspace(1.0, 0.0, ramp, endpoint=False)
        gate[b:b + ramp] = numpy.linspace(0.0, 1.0, ramp, endpoint=False)
    voiced = voiced * gate
    return (0.6 * voiced / numpy.max(numpy.abs(voiced))).astype(numpy.float32)


def music(numpy):
    rate = SAMPLE_RATE
    count = int(2.0 * rate)
    t = numpy.arange(count) / rate
    out = numpy.zeros(count)
    chords = (
        (0.0, (220.00, 277.18, 329.63)),      # A major
        (0.5, (196.00, 246.94, 293.66)),      # G major
        (1.0, (174.61, 220.00, 261.63)),      # F major
        (1.5, (164.81, 207.65, 246.94)),      # E major
    )
    for start, notes in chords:
        local = t - start
        on = local >= 0.0
        for note in notes:
            for partial in range(1, 9):
                decay = numpy.exp(-(3.0 + 1.5 * partial) * numpy.where(on, local, 0.0))
                out += numpy.where(on, decay * numpy.sin(2.0 * numpy.pi * note * partial * local) / partial, 0.0)
    # A click on every beat at 120 BPM: 6 ms of a decaying 1 kHz burst.
    click = int(0.006 * rate)
    for beat in range(4):
        start = int(beat * 0.5 * rate)
        n = numpy.arange(click)
        out[start:start + click] += 1.5 * numpy.exp(-6.0 * n / click) * numpy.sin(2.0 * numpy.pi * 1000.0 * n / rate)
    # The noise floor of a recording: about 46 dB below the peak.
    rng = numpy.random.default_rng(20261116)
    out += 0.005 * numpy.max(numpy.abs(out)) * rng.standard_normal(count)
    return (0.6 * out / numpy.max(numpy.abs(out))).astype(numpy.float32)
