"""The golden script of the MATLAB export of calibration curves (WP-614, §6.14, STG-2).

CalibrationTests builds a report by hand: two entries that measure two implementations each, one
with a crossover on its grid and one without, and an entry with one curve that stands alone.
`CalibrationReport.matlabScript()` must write this file for it, character for character. The
script is written here a second time, from the same figures, the way the export documents it:
for every entry its sizes and the time per call of each implementation as variables, then one
plot per entry of time against size on logarithmic axes, one curve per implementation in the
line styles o-, x--, s: and d-. in turn (MAT-2), numbers at 17 significant digits (MAT-3), no
date and no machine name (MAT-4).

    Tests/ZTronDSPMetalTests/Golden/calibration_report.m

Until WP-910 the script lived in the test as text; it is the same text. Before it is written it
passes the static check of gate 7 (_matlab.lint), and Scripts/golden.sh --octave runs it under
GNU Octave with every other golden script.

    python3 calibration_matlab.py
"""
import os

import _golden
import _matlab

TARGET = "ZTronDSPMetalTests"
NAME = "calibration_report.m"
OUTPUTS = ["Tests/ZTronDSPMetalTests/Golden/calibration_report.m"]
STYLES = ("o-", "x--", "s:", "d-.")

# CrossoverEntry: the raw value, the title and the label of the sizes (CrossoverMeasurement.swift).
ENTRIES = {
    "gainKernel": ("Gain kernel", "Block size (frames)"),
    "laneExchange": ("Lane exchange", "Length (elements)"),
    "medianGPU": ("Median of a spectrogram", "Kernel x bins x frames"),
}

# The report of CalibrationTests.fixture: (entry, sizes, crossover or None, [(label, nanoseconds)]).
MEASUREMENTS = [
    ("gainKernel", [8, 64, 512], 64, [("C loop", [2.5, 20, 160]), ("vDSP_vsmul", [9, 12.25, 40])]),
    ("laneExchange", [8, 4096], None, [("C loop", [5.8, 457]), ("vDSP_vmin, vDSP_vmax", [12, 978])]),
    ("medianGPU", [69768, 279072], None, [("Metal", [1500000, 0.1 + 0.2])]),
]


def summary(crossover, curves):
    names = " against ".join(label for label, _ in curves)
    if len(curves) < 2:
        return "%s, one implementation measured" % names
    return "%s, crossover at %d" % (names, crossover) if crossover is not None else "%s, no crossover on the grid" % names


script = _matlab.Script().comment("ZTronDSP calibration: time per call against size, one curve per implementation.")
for entry, sizes, crossover, curves in MEASUREMENTS:
    script.comment("%s: %s" % (entry, summary(crossover, curves)))
    script.vector("sizes_%s" % entry, [float(size) for size in sizes])
    for index, (_, nanoseconds) in enumerate(curves):
        script.vector("ns_%s_%d" % (entry, index + 1), nanoseconds)
columns = 2 if len(MEASUREMENTS) > 1 else 1
rows = (len(MEASUREMENTS) + columns - 1) // columns
for position, (entry, sizes, crossover, curves) in enumerate(MEASUREMENTS):
    script.subplot(rows, columns, position + 1)
    legend = []
    for index, (label, _) in enumerate(curves):
        style = STYLES[index % len(STYLES)]
        script.plot("sizes_%s" % entry, "ns_%s_%d" % (entry, index + 1), style, command="loglog")
        if index == 0 and len(curves) > 1:
            script.hold()
        legend.append("%s (%s)" % (label, style))
    if len(curves) > 1:
        script.hold(False)
    title, size_label = ENTRIES[entry]
    script.grid().xlabel(size_label).ylabel("Time per call (ns)").title("%s: %s" % (title, ", ".join(legend)))

_matlab.lint(script.text)
path = os.path.join(_golden.folder(TARGET), NAME)
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(script.text)
print("wrote %s (%d lines; the static check of gate 7 passed)" % (os.path.relpath(path, _golden.ROOT), len(script.lines)))
