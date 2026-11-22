"""The golden script of the MATLAB export of a system analysis (WP-440, §6.14, STG-2).

Oracle: scipy.signal.butter for the design in the system, scipy.signal.freqz_zpk for magnitude
and phase, scipy.signal.sosfilt on scipy.signal.zpk2sos for the impulse and step responses. The
group delay is the closed form over the roots; the central difference of the phase of
scipy.signal.freqz_zpk must agree with it at every frequency. scipy.signal.group_delay cannot
serve here: it works on the expanded polynomials, which lose the roots that crowd z = 1 (they
come back 2e-5 away), so it reports a singularity below 30 Hz and is 0.1 sample off at 1 kHz.
It must still agree from 10 kHz up, where those roots no longer matter.

The system, at 48 kHz, is the one the test builds:

    IIRSystem {
        Zero(onUnitCircleAt: .hertz(50))
        Pole(radius: 0.985, frequency: .hertz(50))
        HighPass(.butterworth, cutoff: .hertz(30), order: 2)
        Section(b: [1, -1.9, 0.92], a: [1, -1.85, 0.87])
    }

The script is written the way `SystemAnalysis.matlabScript()` writes it: the same lines, the
same variables in the same order, numbers at 17 significant digits from a double and 9 from a
single (MAT-3), no date and no machine name (MAT-4). Roots are listed element by element, a
conjugate pair of a pole, zero or section with the positive imaginary part first, and the roots
of a design as SciPy returns them. The test reads both scripts back: comments and plot commands
must be equal as text, and every variable must equal the oracle's within its tolerance.

    Tests/ZTronDSPDesignTests/Golden/system_analysis.m

The script is checked for its structure before it is written (`check`): every line is a comment,
an assignment of numbers, or one of the plot commands of MAT-2; data comes before plots; what a
command plots is a variable of the script, or `real`, `imag`, or the unit circle, and the two
things plotted against one another are of one size. That is a check of structure, not Octave.

The script then runs under GNU Octave when `octave` (or `octave-cli`) is on the PATH, headless
(QT_QPA_PLATFORM=offscreen, no window, no start-up files, the figures not shown): it must finish
without an error and leave every variable at its length. Without Octave the script is still
written, and a line says that it was not run; ZTD_REQUIRE_OCTAVE=1 turns that into a failure.
Since WP-910 the Octave run of every golden script, this one among them, is also a part of CI
gate 7 (Scripts/golden.sh --octave), which checks the figure the script draws as well.

    python3 system_analysis_matlab.py
"""
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile

import _golden

numpy, scipy = _golden.oracle()
from scipy import signal  # noqa: E402

TARGET = "ZTronDSPDesignTests"
NAME = "system_analysis.m"
SAMPLE_RATE = 48_000.0
FREQUENCIES = 512          # SystemAnalysis.exportedFrequencyCount
SAMPLES = 256              # SystemAnalysis.exportedSampleCount
HUM = 50.0
POLE_RADIUS = 0.985
RUMBLE = 30.0
SECTION_B = (1.0, -1.9, 0.92)
SECTION_A = (1.0, -1.85, 0.87)


def conjugate_pair(radius, hertz):
    theta = 2.0 * math.pi * hertz / SAMPLE_RATE
    root = complex(radius * math.cos(theta), radius * math.sin(theta))
    return [root, root.conjugate()]


def quadratic_roots(c0, c1, c2):
    """The roots of c0·z² + c1·z + c2 with a negative discriminant: positive imaginary part first."""
    discriminant = c1 * c1 - 4.0 * c0 * c2
    if discriminant >= 0:
        raise ValueError("the section of the fixture has complex roots")
    root = complex(-c1 / (2.0 * c0), math.sqrt(-discriminant) / (2.0 * c0))
    return [root, root.conjugate()]


def system():
    """Zeros, poles and gain of the fixture, element by element."""
    hz, hp, hk = signal.butter(N=2, Wn=RUMBLE, btype="highpass", analog=False, output="zpk", fs=SAMPLE_RATE)
    zeros = conjugate_pair(1.0, HUM) + list(hz) + quadratic_roots(*SECTION_B)
    poles = conjugate_pair(POLE_RADIUS, HUM) + list(hp) + quadratic_roots(*SECTION_A)
    gain = float(hk) * SECTION_B[0] / SECTION_A[0]
    return numpy.array(zeros, dtype=complex), numpy.array(poles, dtype=complex), gain


def group_delay(zeros, poles, omega):
    """−dφ/dω of k·Π(z − zᵢ)/Π(z − pᵢ) on the unit circle: the closed form, root by root."""
    point = numpy.exp(1j * omega)
    delay = numpy.zeros_like(omega)
    for root in zeros:
        delay -= (point / (point - root)).real
    for root in poles:
        delay += (point / (point - root)).real
    return delay


def double(value):
    return "%.17g" % float(value)


def single(value):
    return "%.9g" % float(numpy.float32(value))


def complex_number(value):
    sign = "-" if math.copysign(1.0, value.imag) < 0 else "+"
    return "%s%s%si" % (double(value.real), sign, double(abs(value.imag)))


def vector(name, values, form):
    return "%s = [%s];" % (name, " ".join(form(value) for value in values))


def script():
    zeros, poles, gain = system()
    if not (numpy.max(numpy.abs(poles)) < 1.0):
        raise ValueError("the fixture is stable")

    lowest, highest = SAMPLE_RATE / 4096.0, SAMPLE_RATE / 2.0
    hertz = numpy.array([lowest * math.pow(highest / lowest, index / (FREQUENCIES - 1.0)) for index in range(FREQUENCIES)])
    omega = 2.0 * numpy.pi * hertz / SAMPLE_RATE
    _, response = signal.freqz_zpk(z=zeros, p=poles, k=gain, worN=omega, whole=False, fs=2.0 * numpy.pi)
    magnitude = 20.0 * numpy.log10(numpy.abs(response))
    phase = numpy.unwrap(numpy.angle(response), discont=None, axis=-1, period=2.0 * numpy.pi)
    delay = group_delay(zeros, poles, omega)

    # The oracle of the delay: −dφ/dω by a central difference of SciPy's response.
    step = 1e-5 * omega
    _, above = signal.freqz_zpk(z=zeros, p=poles, k=gain, worN=omega + step, whole=False, fs=2.0 * numpy.pi)
    _, below = signal.freqz_zpk(z=zeros, p=poles, k=gain, worN=omega - step, whole=False, fs=2.0 * numpy.pi)
    differenced = -numpy.angle(above * numpy.conj(below)) / (2.0 * step)
    disagreement = float(numpy.max(numpy.abs(differenced - delay)) / numpy.max(numpy.abs(delay)))
    if disagreement > 1e-7:
        raise ValueError("the differenced phase of scipy.signal.freqz_zpk differs from the closed form by %g of its peak" % disagreement)
    # SciPy's own group delay, where the expanded polynomials still carry it.
    b, a = signal.zpk2tf(zeros, poles, gain)
    high = hertz >= 10_000.0
    _, expanded = signal.group_delay((b, a), w=omega[high], whole=False, fs=2.0 * numpy.pi)
    expanded_disagreement = float(numpy.max(numpy.abs(expanded - delay[high])) / numpy.max(numpy.abs(delay[high])))
    if expanded_disagreement > 1e-9:
        raise ValueError("scipy.signal.group_delay differs from the closed form by %g of its peak from 10 kHz up" % expanded_disagreement)

    sections = signal.zpk2sos(z=zeros, p=poles, k=gain, pairing="nearest", analog=False)
    impulse_input = numpy.zeros(SAMPLES)
    impulse_input[0] = 1.0
    impulse = signal.sosfilt(sections, impulse_input, axis=-1, zi=None)
    step_response = signal.sosfilt(sections, numpy.ones(SAMPLES), axis=-1, zi=None)

    for values in (hertz, magnitude, phase, delay, impulse, step_response):
        if not numpy.all(numpy.isfinite(values)):
            raise ValueError("the fixture has no undefined value")

    lines = [
        "%% ZTronDSP system analysis: a digital system of order %d, infinite impulse response, stable." % len(poles),
        "sample_rate = %s;" % double(SAMPLE_RATE),
        vector("z", zeros, complex_number),
        vector("p", poles, complex_number),
        "k = %s;" % double(gain),
        vector("f", hertz, double),
        vector("magnitude_db", magnitude, double),
        vector("phase_rad", phase, double),
        vector("group_delay", delay, double),
        vector("n", range(SAMPLES), double),
        vector("impulse", impulse, single),
        vector("step", step_response, single),
        "subplot(3, 2, 1);",
        "plot(real(z), imag(z), 'o');",
        "hold on;",
        "plot(real(p), imag(p), 'x');",
        "plot(cos(linspace(0, 2 * pi, 361)), sin(linspace(0, 2 * pi, 361)), 'k:');",
        "hold off;",
        "axis equal;",
        "grid on;",
        "xlabel('Real part');",
        "ylabel('Imaginary part');",
        "title('Poles (x) and zeros (o), with the unit circle');",
    ]
    panels = (
        ("semilogx(f, magnitude_db);", "Frequency (Hz)", "Magnitude (dB)", "Magnitude response"),
        ("semilogx(f, phase_rad);", "Frequency (Hz)", "Phase (rad)", "Phase response, unwrapped"),
        ("semilogx(f, group_delay);", "Frequency (Hz)", "Group delay (samples)", "Group delay"),
        ("stem(n, impulse);", "Sample", "Amplitude", "Impulse response"),
        ("stem(n, step);", "Sample", "Amplitude", "Step response"),
    )
    for index, (command, x, y, title) in enumerate(panels):
        lines += ["subplot(3, 2, %d);" % (index + 2), command, "grid on;", "xlabel('%s');" % x, "ylabel('%s');" % y, "title('%s');" % title]
    return "\n".join(lines) + "\n", disagreement, expanded_disagreement


NUMBER = r"(?:NaN|-?Inf|[-+]?[0-9]+(?:\.[0-9]+)?(?:e[-+]?[0-9]+)?)"
ELEMENT = re.compile(r"^%s(?:[-+]%si)?$" % (NUMBER, NUMBER.replace("[-+]?", "", 1)))
ASSIGNMENT = re.compile(r"^([A-Za-z][A-Za-z0-9_]{0,62}) = (\[[^\[\]]*\]|[^\[\] ]+);$")
PLOT = re.compile(r"^(plot|semilogx|loglog|stem)\((.+)\);$")
OTHER = re.compile(r"^(?:subplot\([1-9][0-9]*, [1-9][0-9]*, [1-9][0-9]*\)|(?:xlabel|ylabel|title)\('(?:[^']|'')*'\)|grid (?:on|off)"
                   r"|hold (?:on|off)|axis (?:equal|tight|square|xy|ij)|colorbar);$")
CIRCLE = re.compile(r"^(?:cos|sin)\(linspace\(0, 2 \* pi, ([1-9][0-9]*)\)\)$")


def arguments(text):
    """The arguments of a call, split at the commas that are not inside brackets or quotes."""
    parts, depth, quoted, current = [], 0, False, ""
    for character in text:
        if character == "'":
            quoted = not quoted
        elif not quoted and character == "(":
            depth += 1
        elif not quoted and character == ")":
            depth -= 1
        if character == "," and depth == 0 and not quoted:
            parts.append(current.strip())
            current = ""
        else:
            current += character
    parts.append(current.strip())
    return parts


def check(text):
    """The structure of a script (MAT-2). Returns (variables: name -> size, plot commands)."""
    if not text.endswith(";\n"):
        raise ValueError("a script ends in a statement and a newline")
    sizes = {}
    plots = 0
    for number, line in enumerate(text[:-1].split("\n"), start=1):
        where = "line %d" % number
        if line.startswith("% "):
            if number != 1:
                raise ValueError("%s: a comment below the head" % where)
            continue
        assignment = ASSIGNMENT.match(line)
        if assignment:
            if plots:
                raise ValueError("%s: %s is defined after the plots began" % (where, assignment.group(1)))
            body = assignment.group(2)
            elements = body[1:-1].split(" ") if body.startswith("[") else [body]
            for element in elements:
                if not ELEMENT.match(element):
                    raise ValueError("%s: '%s' is not a number" % (where, element))
            sizes[assignment.group(1)] = len(elements)
            continue

        def size(expression):
            circle = CIRCLE.match(expression)
            if circle:
                return int(circle.group(1))
            part = re.match(r"^(?:real|imag)\(([A-Za-z][A-Za-z0-9_]*)\)$", expression)
            name = part.group(1) if part else expression
            if name not in sizes:
                raise ValueError("%s: '%s' is not a variable of the script" % (where, expression))
            return sizes[name]

        plot = PLOT.match(line)
        if plot:
            parts = arguments(plot.group(2))
            if len(parts) not in (2, 3) or (len(parts) == 3 and not re.match(r"^'[^']*'$", parts[2])):
                raise ValueError("%s: a plot command takes two things and, at most, a line style" % where)
            if size(parts[0]) != size(parts[1]):
                raise ValueError("%s: %s and %s are not of one size" % (where, parts[0], parts[1]))
            plots += 1
        elif OTHER.match(line):
            plots += 1
        else:
            raise ValueError("%s: '%s' is not a statement a script holds" % (where, line))
    if not plots:
        raise ValueError("the script plots nothing")
    return sizes, plots


def run_under_octave(path):
    """Runs the script under GNU Octave. Returns None when Octave is not installed, else its name."""
    octave = shutil.which("octave") or shutil.which("octave-cli")
    if octave is None:
        return None
    environment = dict(os.environ)
    environment.setdefault("QT_QPA_PLATFORM", "offscreen")
    checks = (
        "set(0, 'defaultfigurevisible', 'off'); "
        "source('%s'); "
        "assert(numel(z) == 6 && numel(p) == 6 && isscalar(k) && sample_rate == 48000); "
        "assert(numel(f) == %d && numel(magnitude_db) == %d && numel(phase_rad) == %d && numel(group_delay) == %d); "
        "assert(numel(n) == %d && numel(impulse) == %d && numel(step) == %d); "
        "assert(all(isfinite(magnitude_db)) && all(isfinite(phase_rad)) && all(isfinite(group_delay))); "
        "disp('ZTD-OCTAVE-OK');"
    ) % ((path.replace("'", "''"),) + (FREQUENCIES,) * 4 + (SAMPLES,) * 3)
    with tempfile.TemporaryDirectory() as scratch:
        result = subprocess.run([octave, "--no-gui", "--quiet", "--norc", "--no-history", "--eval", checks],
                                cwd=scratch, env=environment, capture_output=True, text=True, timeout=300)
    if result.returncode != 0 or "ZTD-OCTAVE-OK" not in result.stdout:
        raise RuntimeError("the script does not run under %s:\n%s\n%s" % (octave, result.stdout.strip(), result.stderr.strip()))
    return octave


def main():
    text, disagreement, expanded_disagreement = script()
    sizes, statements = check(text)
    expected = {"sample_rate": 1, "z": 6, "p": 6, "k": 1, "f": FREQUENCIES, "magnitude_db": FREQUENCIES, "phase_rad": FREQUENCIES,
                "group_delay": FREQUENCIES, "n": SAMPLES, "impulse": SAMPLES, "step": SAMPLES}
    if sizes != expected:
        raise ValueError("the script's variables are %s" % sizes)
    path = os.path.join(_golden.folder(TARGET), NAME)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)
    print("wrote %s (%d lines, structure checked; group delay: the differenced phase of freqz_zpk within %.1e of the closed form, "
          "scipy.signal.group_delay within %.1e from 10 kHz up)" % (
              os.path.relpath(path, _golden.ROOT), text.count("\n"), disagreement, expanded_disagreement))
    octave = run_under_octave(path)
    if octave is not None:
        print("the script runs under %s" % octave)
    elif os.environ.get("ZTD_REQUIRE_OCTAVE") == "1":
        sys.exit("GNU Octave is not installed, and ZTD_REQUIRE_OCTAVE=1 requires the script to run under it")
    else:
        print("GNU Octave is not installed: the script was written and NOT run")


if __name__ == "__main__":
    main()
