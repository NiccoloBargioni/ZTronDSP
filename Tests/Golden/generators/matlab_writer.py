"""The golden script of the MATLAB writer itself (WP-120, §6.14, STG-2; under GNU Octave, WP-910).

MATLABScriptTests builds a script with every kind of variable (a scalar, vectors of doubles and
of singles, a complex vector, matrices of doubles and of singles, a vector with an undefined
value) and every command of MAT-2, and compares its text with this file, character for
character. The script is written here a second time by _matlab.Script, which follows the rules
of §6.14 on its own: 17 significant digits from a double and 9 from a single, `'` doubled inside
a string, one statement per line.

    Tests/ZTronDSPCoreTests/Golden/script_writer.m

Before it is written the script passes the static check of gate 7 (_matlab.lint), and
Scripts/golden.sh --octave runs it under GNU Octave with every other golden script.

    python3 matlab_writer.py
"""
import os

import _golden
import _matlab

numpy, _ = _golden.oracle()

TARGET = "ZTronDSPCoreTests"
NAME = "script_writer.m"
OUTPUTS = ["Tests/ZTronDSPCoreTests/Golden/script_writer.m"]

# Until WP-910 the script lived in the test, written by hand, and did not run: H had three
# columns against the four frequencies of w (Octave: "vector lengths must match"), w began at 0
# on the logarithmic axes of semilogx and loglog, which shared the linear panel of plot, and
# `axis equal` on those axes stopped Octave ("cameratarget must be finite"). Now each kind of
# axes has a panel of its own, every panel that shows data has its labels, and w is positive.
script = (_matlab.Script()
          .comment("Pole-zero map of a second-order section")
          .scalar("fs", 48000)
          .vector("w", [0.125, 0.25, 0.5, 1])
          .singles(numpy, "g", [1, 0.5, 0.25])
          .complex_vector("p", [0.5, 0.5], [0.5, -0.5])
          .rows("H", [[1, 2, 3, 4], [5, 6, 7, 8]])
          .matrix(numpy, "S", [0, 0.5, 1, 1.5, 2, 2.5], 3, 2)
          .optional("d", [1, None, 3])
          .subplot(2, 2, 1)
          .plot("w", "20*log10(abs(H(1,:)))", "r--")
          .hold()
          .plot("real(p)", "imag(p)", "x", command="stem")
          .hold(False)
          .grid()
          .grid(False)
          .xlabel("Frequency (Hz)")
          .ylabel("Magnitude (dB)")
          .title("It's a filter")
          .axis_word("equal")
          .axis(0, 24000, -90, 6)
          .subplot(2, 2, 2)
          .plot("w", "w", command="semilogx")
          .xlabel("Frequency (Hz)")
          .ylabel("Gain")
          .subplot(2, 2, 3)
          .plot("w", "w", command="loglog")
          .xlabel("Frequency (Hz)")
          .ylabel("Gain")
          .subplot(2, 2, 4)
          .imagesc("w", "g", "S")
          .colorbar()
          .xlabel("Time (s)")
          .ylabel("Band"))

_matlab.lint(script.text)
path = os.path.join(_golden.folder(TARGET), NAME)
with open(path, "w", encoding="utf-8", newline="\n") as handle:
    handle.write(script.text)
print("wrote %s (%d lines; the static check of gate 7 passed)" % (os.path.relpath(path, _golden.ROOT), len(script.lines)))
