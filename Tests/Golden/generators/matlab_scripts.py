"""Golden MATLAB scripts for the exports of the analysis target (WP-501g, WP-540, STG-2).

Each case holds the data an export is made from; beside the JSON, `script_<case>.m` is the
script the export must write for it. The scripts are written here a second time, from the same
data, by _matlab.Script, which follows the rules of §6.14 on its own: 17 significant digits from
a double and 9 from a single, core MATLAB only, no date and no machine name.

    heatmap-linear, heatmap-mel    the snapshot of a heat-map feed, with evenly and unevenly
                                   spaced rows
    waveform                       the snapshot of a waveform feed
    scalar-track                   a track of scalar frames
    inversion, inversion-frames    an inversion report measured on samples and on frames
    inversion-conditions           an inversion report without a signal
    window-analysis                the analysis of a Hann window of 64 samples at a hop of 16:
                                   its figures are computed here as the package documents them
                                   (_spectral.window_figures_on_grid), so the test compares the
                                   numbers of the two scripts within round-off, not digit for digit

Every script is read back by _matlab.check, which accepts only the statements of MAT-2, resolves
every variable and function an expression names, and requires what is plotted against one
another to be of one size. That they run under GNU Octave is shown by CI gate 7 since WP-910:
Scripts/golden.sh --octave runs every golden script and compares the figure Octave draws with
the one the static check of Scripts/lib/matlab_check.py expects.

    python3 matlab_scripts.py
"""
import math
import os

import _golden
import _matlab
import _spectral

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPAnalysisTests"
NAMES = ("heatmap-linear", "heatmap-mel", "waveform", "scalar-track", "inversion", "inversion-frames", "inversion-conditions",
         "window-analysis")
# What the generator writes beside its JSON, spelled out: Scripts/golden.sh reads this list
# without running the file.
OUTPUTS = [
    "Tests/ZTronDSPAnalysisTests/Golden/script_heatmap-linear.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_heatmap-mel.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_waveform.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_scalar-track.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_inversion.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_inversion-frames.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_inversion-conditions.m",
    "Tests/ZTronDSPAnalysisTests/Golden/script_window-analysis.m",
]
assert OUTPUTS == [f"Tests/{TARGET}/Golden/script_{name}.m" for name in NAMES]

cases = []
scripts = {}
f32 = numpy.float32


def heatmap(name, rows, columns, row_values, label, even):
    rng = numpy.random.default_rng(540 + rows)
    values = (rng.standard_normal(rows * columns) * 20.0 - 40.0).astype(f32)          # column after column
    times = [0.25 + 0.0625 * c for c in range(columns)]
    by_row = [values[c * rows + r] for r in range(rows) for c in range(columns)]
    script = (_matlab.Script().comment(f"Heat map: {rows} rows, {columns} columns").vector("times", times).vector("row_values", row_values)
              .matrix(numpy, "values", by_row, rows, columns)
              .imagesc("times", "row_values" if even else "1:numel(row_values)", "values").colorbar().xlabel("time (s)")
              .ylabel(label if even else f"row ({label} in row_values)").title("Heat map"))
    scripts[name] = script.text
    cases.append(_golden.case(name, {"rows": rows, "columns": columns},
                              {"values": _golden.real_vector(values), "times": _golden.real_vector(times),
                               "rowValues": _golden.real_vector(row_values)}))


# A linear-frequency axis of 5 bins up to 24 kHz; a mel axis by its band centres.
heatmap("heatmap-linear", 5, 4, [k * 24000.0 / 4 for k in range(5)], "frequency (Hz)", True)
heatmap("heatmap-mel", 3, 6, [180.5, 1250.0, 6400.25], "mel band centre (Hz)", False)

# A waveform: minima and maxima over time.
rng = numpy.random.default_rng(541)
maxima = numpy.abs(rng.standard_normal(7)).astype(f32)
minima = (-numpy.abs(rng.standard_normal(7))).astype(f32)
times = [0.005 * c for c in range(7)]
scripts["waveform"] = (_matlab.Script().comment("Waveform envelope: 7 pairs").vector("times", times).singles(numpy, "minima", minima)
                       .singles(numpy, "maxima", maxima).plot("times", "maxima").hold().plot("times", "minima").hold(False)
                       .xlabel("time (s)").ylabel("amplitude").title("Waveform envelope").grid().text)
cases.append(_golden.case("waveform", {}, {"minima": _golden.real_vector(minima), "maxima": _golden.real_vector(maxima),
                                           "times": _golden.real_vector(times)}))

# A scalar track at 93.75 values per second from 0.5 s on.
values = (220.0 + 5.0 * rng.standard_normal(6)).astype(f32)
confidence = numpy.array([1.0, 0.875, 0.0, 0.5, 1.0, 0.25], dtype=f32)
times = [0.5 + k / 93.75 for k in range(6)]
scripts["scalar-track"] = (_matlab.Script().comment("Scalar track: 6 frames").vector("times", times).singles(numpy, "values", values)
                           .singles(numpy, "confidence", confidence)
                           .subplot(2, 1, 1).plot("times", "values").xlabel("time (s)").ylabel("value").title("Scalar track").grid()
                           .subplot(2, 1, 2).plot("times", "confidence").xlabel("time (s)").ylabel("confidence").grid().text)
cases.append(_golden.case("scalar-track", {"rate": 93.75, "start": 0.5},
                          {"values": _golden.real_vector(values), "confidence": _golden.real_vector(confidence)}))


def inversion(name, original, reconstruction, sample_rate, frame_length):
    """An inversion report with two conditions: one that holds (margin 0.5, accounting for 1e-6),
    and an unnecessary one that fails (margin −0.25, accounting for 0.125)."""
    script = (_matlab.Script().comment("Inversion report: Forward and back through Backward").comment("Every necessary condition holds.")
              .scalar("predicted_error", 1e-6 + 0.125)
              .comment(f"first condition: holds, margin {_matlab.number(0.5)}").comment(f"second condition: fails, margin {_matlab.number(-0.25)}"))
    values = {}
    if original is not None:
        o, r = numpy.asarray(original, dtype=numpy.float64), numpy.asarray(reconstruction, dtype=numpy.float64)
        # Summed value by value, in order, as a loop sums: the digits of the ratio depend on it.
        power, noise = 0.0, 0.0
        for a, b in zip(o.tolist(), r.tolist()):
            power += a * a
            noise += (a - b) * (a - b)
        snr = 10.0 * math.log10(max(power, 1e-300) / noise) if noise > 0 else float("inf")
        frames = frame_length > 1
        position = "0:numel(original)-1" if frames else "(0:numel(original)-1) / sample_rate"
        frequency = "(0:numel(original)-1) / numel(original)" if frames else "(0:numel(original)-1) * sample_rate / numel(original)"
        (script.scalar("sample_rate", sample_rate).scalar("measured_snr", snr).scalar("largest_error", float(numpy.max(numpy.abs(o - r))))
         .singles(numpy, "original", original).singles(numpy, "reconstruction", reconstruction)
         .subplot(3, 1, 1).plot(position, "original").hold().plot(position, "reconstruction", "r--").hold(False)
         .xlabel("value" if frames else "time (s)").ylabel("amplitude").title("Original and reconstruction (dashed)").grid()
         .subplot(3, 1, 2).plot(position, "original - reconstruction").xlabel("value" if frames else "time (s)").ylabel("error").title("Error").grid()
         .subplot(3, 1, 3).plot(frequency, "20 * log10(abs(fft(original - reconstruction)) + 1e-300)")
         .xlabel("cycles per value" if frames else "frequency (Hz)").ylabel("level (dB)").title("Spectrum of the error").grid())
        values = {"original": _golden.real_vector(original), "reconstruction": _golden.real_vector(reconstruction)}
    scripts[name] = script.text
    cases.append(_golden.case(name, {"sampleRate": sample_rate, "frameLength": frame_length}, values))


original = (0.5 * rng.standard_normal(12)).astype(f32)
reconstruction = (original + 1e-4 * rng.standard_normal(12).astype(f32)).astype(f32)
inversion("inversion", original, reconstruction, 8000.0, 1)
inversion("inversion-frames", original, reconstruction, 1.0, 4)
inversion("inversion-conditions", None, None, 48000.0, 1)

# The analysis of a Hann window of 64 samples at a hop of 16.
count, hop = 64, 16
w = signal.get_window("hann", count, fftbins=True)
decibels, step, half, nulls, side, fall_off, scalloping = _spectral.window_figures_on_grid(numpy, w)
total, energy = float(numpy.sum(w)), float(numpy.sum(w * w))
floor = -160.0
nan = float("nan")
scripts["window-analysis"] = (
    _matlab.Script().comment(f"Window analysis: hann, {count} samples, hop {hop}").scalar("frame", count).vector("samples", w)
    .scalar("bin_step", step).vector("spectrum_db", numpy.maximum(decibels, floor))
    .scalar("peak", float(numpy.max(numpy.abs(w)))).scalar("coherent_gain", total / count).scalar("noise_gain", energy / count)
    .scalar("equivalent_noise_bandwidth", count * energy / total ** 2).scalar("main_lobe_half_power", half)
    .scalar("main_lobe_null_to_null", nulls if nulls is not None else nan).scalar("peak_side_lobe", side if side is not None else nan)
    .scalar("side_lobe_fall_off", fall_off if fall_off is not None else nan).scalar("scalloping_loss", scalloping)
    .scalar("smoothness", 2)                                   # the curvature of a Hann window jumps at its edges
    .subplot(2, 1, 1).plot("0:frame-1", "samples").xlabel("sample").ylabel("amplitude").title("Window: hann").grid()
    .subplot(2, 1, 2).plot("(0:numel(spectrum_db)-1) * bin_step", "spectrum_db").hold()
    .plot("[main_lobe_half_power main_lobe_half_power] / 2", f"[{_matlab.number(floor)} 0]", "r--")
    .plot("[main_lobe_null_to_null main_lobe_null_to_null] / 2", f"[{_matlab.number(floor)} 0]", "m--")
    .plot("[0 frame/2]", "[peak_side_lobe peak_side_lobe]", "g--").hold(False).axis(0.0, count / 2.0, floor, 5.0)
    .xlabel("frequency (bins)").ylabel("level (dB)")
    .title("Spectrum: main lobe at -3 dB (red), first null (magenta), highest side lobe (green)").grid().text)
cases.append(_golden.case("window-analysis", {"window": "hann", "frame": count, "hop": hop}, {}))

for name in NAMES:
    statements, variables = _matlab.check(numpy, scripts[name])        # the structural check, in place of Octave
    path = os.path.join(_golden.folder(TARGET), f"script_{name}.m")
    with open(path, "w") as handle:
        handle.write(scripts[name])
    print(f"wrote {os.path.relpath(path, _golden.ROOT)} ({statements} statements, {len(variables)} variables, read back)")

_golden.write(TARGET, "matlab_scripts", cases)
