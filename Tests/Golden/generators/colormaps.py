"""Reference tables of the colour maps (WP-602): what a 256 x 1 look-up texture must hold, byte
for byte.

No oracle library: the tables are the definitions in `_colormaps.py` (the listed colours of
matplotlib's viridis, magma and inferno; the published polynomial of turbo; grayscale), written
out as 768 numbers per map, red, green, blue per entry. `stops-*` are maps through colours of the
test's own, evenly spaced and linear in between.
"""
import _colormaps
import _golden

numpy, _ = _golden.oracle()

cases = []
for name in _colormaps.NAMES:
    cases.append(_golden.case(name, {"map": name}, {"rgb": _golden.real_vector(_colormaps.table(name).astype(float).ravel())}))

custom = {
    "stops-two": [(0.0, 0.0, 0.0), (1.0, 0.5, 0.25)],
    "stops-three": [(0.1, 0.2, 0.9), (1.0, 1.0, 1.0), (0.9, 0.1, 0.0)],
    "stops-seven": [(0.0, 0.0, 0.2), (0.0, 0.3, 0.7), (0.0, 0.7, 0.6), (0.4, 0.8, 0.2), (0.9, 0.8, 0.1), (1.0, 0.4, 0.0), (0.6, 0.0, 0.0)],
}
for name, colors in custom.items():
    cases.append(_golden.case(name, {"map": "stops", "colors": [float(c) for color in colors for c in color]},
                              {"rgb": _golden.real_vector(_colormaps.stops(colors).astype(float).ravel())}))

_golden.write("ZTronDSPMetalTests", "colormaps", cases)
