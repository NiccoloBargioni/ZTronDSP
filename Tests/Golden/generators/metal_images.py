"""Golden images of the Metal renderers (§8.5; WP-603, WP-605, WP-608), from the definition.

No oracle library and no shader: every pixel is computed here, in double precision, from what
§8.2 says a heat map and a waveform show. NumPy and the standard library only.

Heat map. The data are columns of `rows` values; the ring keeps the newest `history` of them.
For the pixel in column i of row j of a W x H image (row 0 at the top):
  * time: x = (i + 0.5) / W; the pixel shows the column of age floor((1 - x) * visible), age 0
    being the newest; an age the ring does not hold shows the lowest value;
  * frequency: with y = 1 - (j + 0.5) / H, the pixel covers the row coordinates between
    R(y - 1/2H) and R(y + 1/2H), clamped to 0 ... rows - 1. For rows evenly spaced in hertz,
    R(u) = F(p0 + u * (p1 - p0)) / (nyquist / (rows - 1)), p being the position on the scale
    (hertz, log2 of hertz from 20 Hz, Slaney mels) of the visible band's ends and F its inverse.
    For rows drawn bin for bin, R(u) = r0 + u * (r1 - r0) - 0.5 over the visible row positions.
    The pixel shows the maximum over that stretch of the values between the rows: linear
    between neighbours, or, for `nearest`, the rows whose cells (one row high, centred on the
    row) the stretch reaches, less a sliver min(stretch / 32, 1 / 64) at each end;
  * colour: t = clamp((value - low) / (high - low)), looked up in the 256-entry table, linear
    between neighbouring entries, each channel rounded to a byte.

Waveform. The data are (minimum, maximum) pairs; the ring keeps the newest `history`. A pixel
covers the ages (1 - x) * visible -/+ visible / 2W, less a sliver min(width / 32, 1 / 64) at each
end, and takes the smallest minimum and the largest maximum of the pairs it reaches. The band
between them, never thinner than one pixel, is filled; the pixel's coverage is the share of its
height inside the band; the colour is fill over background by that coverage.

Every value stored is exactly representable as a half float, which is what the textures hold,
so the images do not depend on that rounding.

Which column, which pair and, for `nearest`, which row a pixel reaches are floors of positions: a
position that falls exactly on a whole number would make the picture depend on the last bit of
the arithmetic that computes it. `off_the_edge` refuses a fixture in which that happens, so no
golden image asks single precision to reproduce a tie.
"""
import math
import os
import struct
import zlib

import _colormaps
import _golden

numpy, _ = _golden.oracle()

TARGET = "ZTronDSPMetalTests"
NYQUIST = 24000.0


# ---------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------

def write_png(name, image):
    """An 8-bit RGB PNG with no ancillary chunk, so a reader has nothing to convert. It lands in
    the target's Golden folder, where the golden runner hashes whatever a generator writes."""
    height, width, _ = image.shape
    raw = b"".join(b"\x00" + image[row].astype(numpy.uint8).tobytes() for row in range(height))

    def chunk(kind, payload):
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b"")
    with open(os.path.join(_golden.folder(TARGET), name), "wb") as handle:
        handle.write(data)


def off_the_edge(what, position):
    """`position` is about to be floored: it must not sit on a whole number, give or take 0.001."""
    if abs(position - round(position)) < 1e-3 and position > 1e-3:
        raise ValueError(f"{what}: the position {position!r} is on the edge between two entries; choose other figures for the fixture")
    return position


def half(values):
    """The values rounded to what a half-float texel holds."""
    return numpy.asarray(values, dtype=numpy.float64).astype(numpy.float16).astype(numpy.float64)


# ---------------------------------------------------------------------------------------------
# Scales
# ---------------------------------------------------------------------------------------------

LOWEST = 20.0
MEL_BREAK_HERTZ, MEL_BREAK, HERTZ_PER_MEL, MEL_LOG_STEP = 1000.0, 15.0, 200.0 / 3.0, math.log(6.4) / 27.0


def position(scale, hertz):
    if scale == "linear":
        return hertz
    if scale == "logarithmic":
        return math.log2(max(hertz, LOWEST))
    if scale == "mel":
        hertz = max(hertz, 0.0)
        return hertz / HERTZ_PER_MEL if hertz < MEL_BREAK_HERTZ else MEL_BREAK + math.log(hertz / MEL_BREAK_HERTZ) / MEL_LOG_STEP
    raise ValueError(scale)


def frequency(scale, where):
    if scale == "linear":
        return where
    if scale == "logarithmic":
        return 2.0 ** where
    if scale == "mel":
        return where * HERTZ_PER_MEL if where < MEL_BREAK else MEL_BREAK_HERTZ * math.exp(MEL_LOG_STEP * (where - MEL_BREAK))
    raise ValueError(scale)


# ---------------------------------------------------------------------------------------------
# The heat map
# ---------------------------------------------------------------------------------------------

def render_heatmap(columns, history, width, height, table, low, high, scale=None, band=None, rows_shown=None,
                   visible=None, nearest=False):
    """`columns`: every column appended, oldest first, shape (count, rows). `scale`: a scale name
    for rows evenly spaced in hertz up to NYQUIST, or None for rows drawn bin for bin."""
    count, rows = columns.shape
    available = min(count, history)
    visible = float(history) if visible is None else visible
    table = table.astype(numpy.float64)
    top = rows - 1

    def row_coordinate(unit):
        if scale is None:
            first, last = (0.0, float(rows)) if rows_shown is None else rows_shown
            return first + unit * (last - first) - 0.5
        full = (position(scale, 0.0), position(scale, NYQUIST))
        shown = full if band is None else (position(scale, band[0]), position(scale, band[1]))
        shown = (min(max(shown[0], full[0]), full[1]), min(max(shown[1], full[0]), full[1]))
        return frequency(scale, shown[0] + unit * (shown[1] - shown[0])) / (NYQUIST / top)

    def between(column, row):
        below = min(int(math.floor(row)), top)
        above = min(below + 1, top)
        return column[below] + (column[above] - column[below]) * (row - below)

    image = numpy.zeros((height, width, 3), dtype=numpy.uint8)
    for j in range(height):
        unit = 1.0 - (j + 0.5) / height
        a = row_coordinate(unit - 0.5 / height)
        b = row_coordinate(unit + 0.5 / height)
        lowest = min(max(min(a, b), 0.0), top)
        highest = min(max(max(a, b), 0.0), top)
        for i in range(width):
            age = int(math.floor(off_the_edge("column", max((1.0 - (i + 0.5) / width) * visible, 0.0))))
            value = low
            if age < available:
                column = columns[count - 1 - age]
                if nearest:
                    sliver = min((highest - lowest) / 32.0, 1.0 / 64.0)
                    first = min(int(math.floor(off_the_edge("row", lowest + sliver + 0.5))), top)
                    last = min(int(math.floor(off_the_edge("row", max(highest - sliver, lowest) + 0.5))), top)
                    value = column[first:max(first, last) + 1].max()
                else:
                    value = max(between(column, lowest), between(column, highest))
                    first, last = int(math.ceil(lowest)), int(math.floor(highest))
                    if first <= last:
                        value = max(value, column[first:last + 1].max())
            scaled = min(max((value - low) / (high - low), 0.0), 1.0) * 255.0
            entry = min(int(math.floor(scaled)), 254)
            color = table[entry] + (table[entry + 1] - table[entry]) * (scaled - entry)
            image[j, i] = numpy.floor(color + 0.5)
    return image


# ---------------------------------------------------------------------------------------------
# The waveform
# ---------------------------------------------------------------------------------------------

def render_waveform(pairs, history, width, height, low, high, fill, background, visible=None):
    """`pairs`: every (minimum, maximum) appended, oldest first, shape (count, 2)."""
    count = pairs.shape[0]
    available = min(count, history)
    visible = float(history) if visible is None else visible
    per_pixel = visible / width
    sliver = min(per_pixel / 32.0, 1.0 / 64.0)
    fill = numpy.asarray(fill, dtype=numpy.float64)
    background = numpy.asarray(background, dtype=numpy.float64)
    image = numpy.zeros((height, width, 3), dtype=numpy.uint8)
    pixel = 1.0 / height
    for i in range(width):
        centre = (1.0 - (i + 0.5) / width) * visible
        youngest = off_the_edge("pair", max(centre - 0.5 * per_pixel + sliver, 0.0))
        oldest = off_the_edge("pair", max(centre + 0.5 * per_pixel - sliver, youngest))
        first = int(math.floor(youngest))
        extent = None
        if first < available:
            last = min(int(math.floor(oldest)), available - 1)
            reached = pairs[count - 1 - last:count - first]
            extent = (reached[:, 0].min(), reached[:, 1].max())
        for j in range(height):
            unit = 1.0 - (j + 0.5) / height
            coverage = 0.0
            if extent is not None:
                bottom = (extent[0] - low) / (high - low)
                top = (extent[1] - low) / (high - low)
                middle = 0.5 * (bottom + top)
                half_band = max(0.5 * (top - bottom), 0.5 * pixel)
                covered = min(middle + half_band, unit + 0.5 * pixel) - max(middle - half_band, unit - 0.5 * pixel)
                coverage = min(max(covered / pixel, 0.0), 1.0)
            color = fill * coverage + background * (1.0 - coverage)
            image[j, i] = numpy.floor(255.0 * color + 0.5)
    return image


# ---------------------------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------------------------

def spectrogram(count, rows):
    """Decibels from about -100 to +5: a floor, three gliding partials, a broadband burst and a
    low-frequency hump. Smooth, so the picture says where a mapping went wrong."""
    time = numpy.arange(count)[:, None] / 96.0
    hertz = numpy.arange(rows)[None, :] * (NYQUIST / (rows - 1))
    level = -95.0 + 12.0 * numpy.sin(2.0 * numpy.pi * (0.7 * time + hertz / 9000.0))
    fundamental = 700.0 * 2.0 ** (1.6 * time)
    for partial in (1, 2, 3, 5, 8):
        width = 60.0 + 25.0 * partial
        ridge = (5.0 - 9.0 * math.log2(partial)) - 0.5 * ((hertz - partial * fundamental) / width) ** 2 * 8.0
        level = numpy.maximum(level, ridge)
    burst = -8.0 - 900.0 * (time - 0.55) ** 2 * 60.0 - 20.0 * hertz / NYQUIST
    hump = -20.0 - ((hertz - 150.0) / 120.0) ** 2 * 6.0 + 6.0 * numpy.cos(2.0 * numpy.pi * 2.0 * time)
    level = numpy.maximum(level, numpy.maximum(burst, hump))
    return half(numpy.clip(level, -100.0, 5.0))


def peaks(count, rows, bins):
    """-90 dB everywhere, 0 dB in the given bins of every column."""
    level = numpy.full((count, rows), -90.0)
    for index in bins:
        level[:, index] = 0.0
    return half(level)


def chroma(count):
    """Twelve pitch classes in 0 ... 1: a scale climbing through the classes, over a drone."""
    level = numpy.zeros((count, 12))
    for column in range(count):
        level[column, (column // 8) % 12] = 1.0
        level[column, ((column // 8) + 4) % 12] = 0.55
        level[column, 7] = max(level[column, 7], 0.3)
    return half(level)


def bands(count, rows):
    """Mel-like bands in decibels: two ridges crossing."""
    time = numpy.arange(count)[:, None] / count
    band = numpy.arange(rows)[None, :]
    level = numpy.maximum(-6.0 * numpy.abs(band - (8.0 + 40.0 * time)), -6.0 * numpy.abs(band - (56.0 - 44.0 * time))) - 10.0
    return half(numpy.clip(level, -80.0, 0.0))


def envelope(samples, bucket):
    """One (minimum, maximum) pair per `bucket` samples."""
    count = len(samples) // bucket
    blocks = numpy.asarray(samples[:count * bucket]).reshape(count, bucket)
    return half(numpy.stack([blocks.min(axis=1), blocks.max(axis=1)], axis=1))


cases = []
HEAT_WIDTH, HEAT_HEIGHT = 192, 128
HISTORY, ROWS = 96, 257


def heat_case(name, data_name, data, history, table_name, low, high, width=HEAT_WIDTH, height=HEAT_HEIGHT, appended=None, **keywords):
    appended = data.shape[0] if appended is None else appended
    table = _colormaps.table(table_name)
    image = render_heatmap(data[:appended], history, width, height, table, low, high, **keywords)
    write_png(name + ".png", image)
    parameters = {
        "kind": "heatmap", "data": data_name, "rows": int(data.shape[1]), "appended": int(appended), "history": int(history),
        "width": width, "height": height, "colorMap": table_name, "low": float(low), "high": float(high),
        "scale": keywords.get("scale") or "rows", "nearest": bool(keywords.get("nearest", False)), "image": name + ".png",
    }
    if keywords.get("band") is not None:
        parameters["band"] = [float(v) for v in keywords["band"]]
    if keywords.get("rows_shown") is not None:
        parameters["rowsShown"] = [float(v) for v in keywords["rows_shown"]]
    if keywords.get("visible") is not None:
        parameters["visible"] = float(keywords["visible"])
    cases.append(_golden.case(name, parameters, {"reference": _golden.real_vector([float(image.mean())])}))


data_sets = {}
data_sets["spectrogram"] = spectrogram(150, ROWS)
data_sets["peaks"] = peaks(HISTORY, ROWS, (3, 40, 200, 251))
data_sets["chroma"] = chroma(HISTORY)
data_sets["bands"] = bands(HISTORY, 64)

# Each frequency scale.
for scale in ("linear", "logarithmic", "mel"):
    heat_case(f"heatmap-{scale}", "spectrogram", data_sets["spectrogram"], HISTORY, "viridis", -90.0, 0.0, appended=HISTORY, scale=scale)
# Each colour map (viridis is above).
for table_name in ("magma", "inferno", "turbo", "grayscale"):
    heat_case(f"heatmap-{table_name}", "spectrogram", data_sets["spectrogram"], HISTORY, table_name, -90.0, 0.0, appended=HISTORY, scale="linear")
# Ring wrap-around: 150 columns through a ring of 96.
heat_case("heatmap-wrap", "spectrogram", data_sets["spectrogram"], HISTORY, "viridis", -90.0, 0.0, scale="linear")
# A ring that is not full yet: the left of the picture holds no column.
heat_case("heatmap-partial", "spectrogram", data_sets["spectrogram"], HISTORY, "viridis", -90.0, 0.0, appended=40, scale="linear")
# Range clamping at both ends: the data reach from -100 to +5.
heat_case("heatmap-clamp", "spectrogram", data_sets["spectrogram"], HISTORY, "viridis", -60.0, -20.0, appended=HISTORY, scale="linear")
# A one-bin peak under each scale: four of them, two rows of pixels apart at the least.
for scale in ("linear", "logarithmic", "mel"):
    heat_case(f"heatmap-peak-{scale}", "peaks", data_sets["peaks"], HISTORY, "inferno", -90.0, 0.0, scale=scale)
# A visible band and a time span: uniforms only.
heat_case("heatmap-zoom", "spectrogram", data_sets["spectrogram"], HISTORY, "magma", -90.0, 0.0, appended=HISTORY, scale="logarithmic",
          band=(500.0, 9000.0), visible=40.5)
# Rows drawn bin for bin: nearest for pitch classes, linear for bands, a row range.
heat_case("heatmap-chroma", "chroma", data_sets["chroma"], HISTORY, "viridis", 0.0, 1.0, height=120, nearest=True)
heat_case("heatmap-bands", "bands", data_sets["bands"], HISTORY, "magma", -60.0, 0.0)
heat_case("heatmap-band-range", "bands", data_sets["bands"], HISTORY, "magma", -60.0, 0.0, rows_shown=(6.0, 30.5), nearest=True)

WAVE_WIDTH, WAVE_HEIGHT = 192, 96
FILL, BACKGROUND = (0.2, 0.8, 1.0), (0.05, 0.05, 0.1)


def wave_case(name, data_name, data, history, low=-1.0, high=1.0, visible=None):
    image = render_waveform(data, history, WAVE_WIDTH, WAVE_HEIGHT, low, high, FILL, BACKGROUND, visible=visible)
    write_png(name + ".png", image)
    parameters = {
        "kind": "waveform", "data": data_name, "appended": int(data.shape[0]), "history": int(history), "width": WAVE_WIDTH,
        "height": WAVE_HEIGHT, "low": float(low), "high": float(high), "fill": [float(v) for v in FILL],
        "background": [float(v) for v in BACKGROUND], "image": name + ".png",
    }
    if visible is not None:
        parameters["visible"] = float(visible)
    cases.append(_golden.case(name, parameters, {"reference": _golden.real_vector([float(image.mean())])}))


sample = numpy.arange(256 * 32)
sine = numpy.sin(2.0 * numpy.pi * 220.0 * sample / 48000.0)
impulse = numpy.zeros(256 * 32)
impulse[100 * 32 + 5] = 1.0
swell = numpy.sin(2.0 * numpy.pi * 997.0 * numpy.arange(2048 * 16) / 48000.0) * (0.15 + 0.8 * numpy.sin(numpy.pi * numpy.arange(2048 * 16) / (2048 * 16)) ** 2)
swell[700 * 16 + 3] = 1.2          # one sample that only a reduction over every pair keeps
data_sets["wave-sine"] = envelope(0.8 * sine, 32)
data_sets["wave-impulse"] = envelope(impulse, 32)
data_sets["wave-silence"] = envelope(numpy.zeros(256 * 32), 32)
data_sets["wave-clipped"] = envelope(1.6 * sine, 32)
data_sets["wave-long"] = envelope(0.9 * numpy.sin(2.0 * numpy.pi * 150.0 * numpy.arange(400 * 32) / 48000.0) * numpy.linspace(0.2, 1.0, 400 * 32), 32)
data_sets["wave-swell"] = envelope(swell, 16)

wave_case("waveform-sine", "wave-sine", data_sets["wave-sine"], 256)
wave_case("waveform-impulse", "wave-impulse", data_sets["wave-impulse"], 256)
wave_case("waveform-silence", "wave-silence", data_sets["wave-silence"], 256)
wave_case("waveform-clipped", "wave-clipped", data_sets["wave-clipped"], 256)
# 400 pairs through a ring of 256, and a span that magnifies them.
wave_case("waveform-wrap", "wave-long", data_sets["wave-long"], 256, visible=100.7)
# Many pairs per pixel, and another amplitude range.
wave_case("waveform-minified", "wave-swell", data_sets["wave-swell"], 2048, low=-0.5, high=1.25)

# The data, once each.
for data_name, data in data_sets.items():
    cases.append(_golden.case("data-" + data_name, {"kind": "data"},
                              {"values": _golden.raw_array(TARGET, "metal_images_" + data_name.replace("-", "_") + ".f32", data, dtype="f32")}))

# A picture whose every pixel is a formula, for the loader's self-test (WP-603):
# red = x, green = y, blue = (3x + 5y) mod 256, over 64 x 48.
x, y = numpy.meshgrid(numpy.arange(64), numpy.arange(48))
write_png("loader-pattern.png", numpy.stack([x, y, (3 * x + 5 * y) % 256], axis=2).astype(numpy.uint8))

_golden.write(TARGET, "metal_images", cases)
