"""Writes the xccov-shaped reports of this fixture directory. Run it after changing `tree/`.

    python3 Tests/Fixtures/Coverage/generate.py

Paths are spelled as on a build machine (/build/ZTronDSP/…), so the gate has to find the
package-relative part by itself.
"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
BUILD = "/build/ZTronDSP/"


def totals(path, covered, executable):
    return {"name": os.path.basename(path), "path": BUILD + path, "coveredLines": covered, "executableLines": executable,
            "lineCoverage": covered / executable if executable else 0, "functions": []}


def report(*targets):
    """targets: (name, [file dict, …])"""
    out = {"targets": []}
    for name, files in targets:
        covered = sum(f["coveredLines"] for f in files)
        executable = sum(f["executableLines"] for f in files)
        out["targets"].append({"name": name, "buildProductPath": "/build/DerivedData/" + name, "coveredLines": covered,
                               "executableLines": executable, "lineCoverage": covered / executable if executable else 0, "files": files})
    out["coveredLines"] = sum(t["coveredLines"] for t in out["targets"])
    out["executableLines"] = sum(t["executableLines"] for t in out["targets"])
    out["lineCoverage"] = out["coveredLines"] / out["executableLines"] if out["executableLines"] else 0
    return out


def lines(count, executed, unexecuted=()):
    """A per-line record: `executed` and `unexecuted` are executable; every other line is not."""
    out = []
    for number in range(1, count + 1):
        if number in executed:
            out.append({"line": number, "isExecutable": True, "executionCount": 3})
        elif number in unexecuted:
            out.append({"line": number, "isExecutable": True, "executionCount": 0})
        else:
            out.append({"line": number, "isExecutable": False})
    return out


def write(name, data):
    with open(os.path.join(HERE, name), "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=1, sort_keys=True)
        handle.write("\n")


EXCLUDED = [
    totals("Sources/ZTronDSPTesting/Probe.swift", 0, 100),            # the test product: outside the denominator
    totals("Tests/ZTronDSPCoreTests/UnitsTests.swift", 50, 100),      # tests: outside the denominator
    totals("Examples/ZTronDSPGallery/Gallery.swift", 0, 400),
    {"name": "resource_bundle_accessor.swift", "path": "/build/DerivedData/Build/Intermediates.noindex/DerivedSources/resource_bundle_accessor.swift",
     "coveredLines": 0, "executableLines": 30, "lineCoverage": 0, "functions": []},
]

# Every threshold met. Toolkit.swift appears under two test bundles, as Xcode reports a package
# target once per bundle that links it; the better-covered record is the one that counts.
write("report-pass.json", report(
    ("ZTronDSPCoreTests", [totals("Sources/ZTronDSPCore/Toolkit.swift", 198, 200), totals("Sources/CZTronDSP/kernel.c", 50, 50)] + EXCLUDED),
    ("ZTronDSPDesignTests", [totals("Sources/ZTronDSPCore/Toolkit.swift", 150, 200), totals("Sources/ZTronDSPDesign/Design.swift", 97, 100)]),
))

# 96.0 % in all, every target at 95 % or above: only the aggregate threshold is missed.
write("report-fail-aggregate.json", report(
    ("ZTronDSPCoreTests", [totals("Sources/ZTronDSPCore/Toolkit.swift", 190, 200), totals("Sources/CZTronDSP/kernel.c", 50, 50),
                           totals("Sources/ZTronDSPDesign/Design.swift", 96, 100)]),
))

# 99.5 % in all, ZTronDSPDesign at 90 %: only a per-target threshold is missed.
write("report-fail-target.json", report(
    ("ZTronDSPCoreTests", [totals("Sources/ZTronDSPCore/Toolkit.swift", 2000, 2000), totals("Sources/CZTronDSP/kernel.c", 50, 50),
                           totals("Sources/ZTronDSPDesign/Design.swift", 90, 100)]),
))

# ZTronDSPDesign is missing altogether although tree/ holds code for it.
write("report-target-missing.json", report(
    ("ZTronDSPCoreTests", [totals("Sources/ZTronDSPCore/Toolkit.swift", 200, 200), totals("Sources/CZTronDSP/kernel.c", 50, 50)]),
))

# Nothing but excluded code.
write("report-nothing.json", report(("ZTronDSPCoreTests", EXCLUDED)))

# The per-line shape. Units.swift: lines 5, 6 and 12 are unexecuted and marked in tree/.
PADDING = {BUILD + "Sources/ZTronDSPCore/Padding.swift": lines(900, set(range(1, 901)))}
UNITS = BUILD + "Sources/ZTronDSPCore/Units.swift"
write("lines-pass.json", dict(PADDING, **{UNITS: lines(16, {3, 4, 7, 8, 9, 11, 13, 14, 15}, {5, 6, 12})}))
# The same file with one more unexecuted line (14) that nothing marks: 8 of 9 lines after the marks.
write("lines-fail-file.json", dict(PADDING, **{UNITS: lines(16, {3, 4, 7, 8, 9, 11, 13, 15}, {5, 6, 12, 14})}))
# Without the padding the three marked lines are 25 % of the production lines.
write("lines-cap.json", {UNITS: lines(16, {3, 4, 7, 8, 9, 11, 13, 14, 15}, {5, 6, 12})})
# A second run (a device) that executes line 14: merged with lines-fail-file.json the file passes.
write("lines-device.json", {UNITS: lines(16, {14}, {3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 15})})
# Totals for the file that carries marks: marks cannot be read against totals.
write("report-units-totals.json", report(
    ("ZTronDSPCoreTests", [totals("Sources/ZTronDSPCore/Units.swift", 9, 12), totals("Sources/ZTronDSPCore/Toolkit.swift", 900, 900)]),
))
# For tree-marks-bad/: line 2 unexecuted (mark without a reason), line 3 executed, line 7 executed.
write("lines-marks-bad.json", {BUILD + "Sources/ZTronDSPCore/Marks.swift": lines(8, {1, 3, 7, 8}, {2})})
