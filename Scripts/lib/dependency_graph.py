"""Confirms that the package's dependency graph equals §4.2 of the specification (WP-001).

    dependency_graph.py [--manifest-json FILE|-] [--sources DIR]

Without --manifest-json the manifest is read with `swift package dump-package`, and the
sources of the package are scanned as well. With it, sources are scanned only when --sources
names a tree. Exit status: 0 equal, 1 deviations, 2 usage error.

What is compared:
  * the targets and their dependencies, edge for edge (§4.2), and their order (DEP-1): a target
    depends only on targets listed above it. CZTronDSPTesting is the C half of ZTronDSPTesting;
  * the products, the platform floor (PLAT-1), the tools version and language modes (§9.2), the
    function-effect errors of the C target (RT-1, E-32), the absence of unsafe flags and of
    third-party dependencies (DEP-3), one test target per target;
  * in the sources: a file imports a module of this package only when its target declares that
    dependency (DEP-1); ZTronDSPCore imports neither AVFAudio nor Metal (DEP-1); only ZTronDSPUI
    imports MetalKit (DEP-2); in CZTronDSP only Objective-C files and headers include AVFAudio.
"""

import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import source_scan as scan  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# §4.2, top to bottom. The order is the dependency rule DEP-1.
EXPECTED = [
    ("CZTronDSP", []),
    ("ZTronDSPCore", ["CZTronDSP"]),
    ("ZTronDSPDesign", ["ZTronDSPCore"]),
    ("ZTronDSPMetal", ["ZTronDSPCore"]),
    ("ZTronDSPAnalysis", ["ZTronDSPCore", "ZTronDSPDesign", "ZTronDSPMetal"]),
    ("ZTronDSPIO", ["ZTronDSPCore", "CZTronDSP"]),
    ("ZTronDSPUI", ["ZTronDSPCore", "ZTronDSPAnalysis", "ZTronDSPMetal"]),
    ("ZTronDSP", ["ZTronDSPCore", "ZTronDSPDesign", "ZTronDSPAnalysis", "ZTronDSPIO", "ZTronDSPMetal"]),
    ("ZTronDSPTesting", ["ZTronDSPCore", "CZTronDSPTesting"]),
]
# One SwiftPM target holds one language, so the C half of the test product is a target of its own.
C_HALVES = {"CZTronDSPTesting": "ZTronDSPTesting"}
C_TARGETS = ("CZTronDSP", "CZTronDSPTesting")
PRODUCTS = ("ZTronDSP", "ZTronDSPUI", "ZTronDSPTesting")
CORE_MUST_NOT_IMPORT = ("AVFAudio", "AVFoundation", "Metal", "MetalKit", "MetalPerformanceShaders", "MetalPerformanceShadersGraph")

SWIFT_IMPORT = re.compile(
    r"^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|internal|private|fileprivate|package)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|var|let)[ \t]+)?([A-Za-z_]\w*)", re.MULTILINE)
C_INCLUDE = re.compile(r"^[ \t]*#[ \t]*(?:import|include)[ \t]*[<\"]([A-Za-z_]\w*)/|^[ \t]*@import[ \t]+([A-Za-z_]\w*)", re.MULTILINE)


def dependency_names(target):
    names = []
    for dependency in target.get("dependencies", []):
        for kind in ("byName", "target", "product"):
            if kind in dependency:
                names.append(dependency[kind][0])
    return names


def check_manifest(manifest):
    problems = []
    rank = {name: index for index, (name, _) in enumerate(EXPECTED)}
    for half, whole in C_HALVES.items():
        rank[half] = rank[whole]
    expected = dict(EXPECTED)
    for half in C_HALVES:
        expected[half] = []

    if manifest.get("name") != "ZTronDSP":
        problems.append("the package is named '%s', not ZTronDSP" % manifest.get("name"))

    version = (manifest.get("toolsVersion") or {}).get("_version", "")
    if not re.match(r"^6\.2(\.\d+)?$", version):
        problems.append("swift-tools-version is %s; §9.2 fixes 6.2 (E-32)" % (version or "missing"))

    platforms = [(p.get("platformName"), p.get("version")) for p in manifest.get("platforms") or []]
    if platforms != [("ios", "15.0")]:
        problems.append("platforms are %s; PLAT-1 fixes [.iOS(.v15)]" % (platforms or "not declared"))

    if manifest.get("dependencies"):
        named = [d.get("identity") or next(iter(d.values()), [{}])[0].get("identity", "?") if isinstance(d, dict) else "?" for d in manifest["dependencies"]]
        problems.append("the package declares %d package dependenc%s (%s); DEP-3 allows none" % (
            len(manifest["dependencies"]), "y" if len(manifest["dependencies"]) == 1 else "ies", ", ".join(str(n) for n in named)))

    if manifest.get("cLanguageStandard") != "c11":
        problems.append("cLanguageStandard is %s; CZTronDSP is C11 (§4.2)" % manifest.get("cLanguageStandard"))

    targets = {t["name"]: t for t in manifest.get("targets", [])}
    regular = {name: t for name, t in targets.items() if t.get("type") != "test"}
    tests = {name: t for name, t in targets.items() if t.get("type") == "test"}

    for name in expected:
        if name not in regular:
            problems.append("target %s of §4.2 is missing" % name)
    for name in regular:
        if name not in expected:
            problems.append("target %s is not in §4.2" % name)

    for name, target in regular.items():
        if name not in expected:
            continue
        actual, wanted = dependency_names(target), expected[name]
        for dependency in actual:
            if dependency not in wanted:
                problems.append("%s depends on %s, which §4.2 does not list for it" % (name, dependency))
            if dependency in rank and rank[dependency] > rank[name]:
                problems.append("%s depends on %s, which is listed below it (DEP-1)" % (name, dependency))
            if dependency in rank and rank[dependency] == rank[name] and C_HALVES.get(dependency) != name:
                problems.append("%s depends on %s, which is not listed above it (DEP-1)" % (name, dependency))
        for dependency in wanted:
            if dependency not in actual:
                problems.append("%s does not depend on %s, which §4.2 lists for it" % (name, dependency))
        if len(set(actual)) != len(actual):
            problems.append("%s lists a dependency twice" % name)

    package_modes = manifest.get("swiftLanguageVersions") or []
    for name, target in targets.items():
        settings = target.get("settings", [])
        for setting in settings:
            if "unsafeFlags" in (setting.get("kind") or {}):
                problems.append("%s uses unsafeFlags, which bars the package from being a dependency (E-32)" % name)
        if name in C_TARGETS:
            continue
        modes = [s["kind"]["swiftLanguageMode"].get("_0") for s in settings if "swiftLanguageMode" in (s.get("kind") or {})]
        if modes != ["6"] and package_modes != ["6"]:
            problems.append("%s is not in the Swift 6 language mode (§9.2)" % name)

    if "CZTronDSP" in regular:
        kinds = [s.get("kind") or {} for s in regular["CZTronDSP"].get("settings", []) if s.get("tool") == "c"]
        enabled = any(k.get("enableWarning", {}).get("_0") == "function-effects" for k in kinds)
        as_error = any(k.get("treatWarning", {}).get("_0") == "function-effects" and k.get("treatWarning", {}).get("_1") == "error" for k in kinds)
        if not (enabled and as_error):
            problems.append("CZTronDSP does not turn function-effect warnings into errors (RT-1, E-32)")

    products = {p["name"]: p for p in manifest.get("products", [])}
    for name in PRODUCTS:
        if name not in products:
            problems.append("product %s of §4.2 is missing" % name)
        elif name not in products[name].get("targets", []):
            problems.append("product %s does not hold the target %s" % (name, name))
    for name in products:
        if name not in PRODUCTS:
            problems.append("product %s is not in §4.2" % name)

    for name, _ in EXPECTED:
        test_name = name + "Tests"
        if test_name not in tests:
            problems.append("there is no test target %s (§4.2: one test target per target)" % test_name)
        elif name not in dependency_names(tests[test_name]):
            problems.append("%s does not depend on %s" % (test_name, name))
    for name in tests:
        if not name.endswith("Tests") or name[:-len("Tests")] not in dict(EXPECTED):
            problems.append("test target %s belongs to no target of §4.2" % name)

    return problems


def check_sources(tree):
    problems = []
    expected = dict(EXPECTED)
    for half in C_HALVES:
        expected[half] = []
    modules = set(expected)
    sources = os.path.join(tree, "Sources")
    if not os.path.isdir(sources):
        return ["there is no Sources directory under %s" % tree]
    for directory, names, files in os.walk(sources):
        names.sort()
        for filename in sorted(files):
            path = os.path.join(directory, filename)
            relative = os.path.relpath(path, tree).replace(os.sep, "/")
            target = relative.split("/")[1] if relative.count("/") >= 2 else None
            if target not in expected:
                continue
            is_swift = filename.endswith(".swift")
            if not is_swift and not filename.endswith(scan.C_EXTENSIONS):
                continue
            with open(path, encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            masked = scan.mask(relative, text)
            if is_swift:
                found = [(m.group(1), m.start(1)) for m in SWIFT_IMPORT.finditer(masked)]
            else:
                found = [(m.group(1) or m.group(2), m.start()) for m in C_INCLUDE.finditer(masked)]
            for module, offset in found:
                where = "%s:%d" % (relative, scan.line_of(text, offset))
                if is_swift and module in modules and module != target and module not in expected[target]:
                    problems.append("%s: %s imports %s, which is not among its dependencies in §4.2 (DEP-1)" % (where, target, module))
                if target == "ZTronDSPCore" and module in CORE_MUST_NOT_IMPORT:
                    problems.append("%s: ZTronDSPCore imports %s (DEP-1: neither AVFAudio nor Metal)" % (where, module))
                if module == "MetalKit" and target != "ZTronDSPUI":
                    problems.append("%s: %s imports MetalKit; only ZTronDSPUI may (DEP-2)" % (where, target))
                if target == "CZTronDSP" and module in ("AVFAudio", "AVFoundation") and filename.endswith(".c"):
                    problems.append("%s: a C file includes %s; in CZTronDSP only the Objective-C sink-node factory does (§4.2)" % (where, module))
    return problems


def main(arguments):
    manifest_path, sources = None, None
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("--manifest-json", "--sources") and index + 1 < len(arguments):
            index += 1
            if argument == "--manifest-json":
                manifest_path = arguments[index]
            else:
                sources = arguments[index]
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            print("check-dependency-graph: unknown argument %s" % argument, file=sys.stderr)
            return 2
        index += 1

    if manifest_path is None:
        result = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT, capture_output=True, text=True)
        if result.returncode != 0:
            print("check-dependency-graph: `swift package dump-package` failed:\n" + result.stderr, file=sys.stderr)
            return 2
        text = result.stdout
        sources = sources or ROOT
    elif manifest_path == "-":
        text = sys.stdin.read()
    else:
        if not os.path.isfile(manifest_path):
            print("check-dependency-graph: no file at %s" % manifest_path, file=sys.stderr)
            return 2
        with open(manifest_path, encoding="utf-8") as handle:
            text = handle.read()
    try:
        manifest = json.loads(text)
    except ValueError as error:
        print("check-dependency-graph: the manifest is not JSON: %s" % error, file=sys.stderr)
        return 2

    problems = check_manifest(manifest)
    if sources is not None:
        problems += check_sources(sources)
    for problem in problems:
        print("check-dependency-graph: " + problem)
    if problems:
        print("check-dependency-graph: %d deviation%s from §4.2" % (len(problems), "" if len(problems) == 1 else "s"))
        return 1
    print("check-dependency-graph: the graph equals §4.2 (%d targets, %d products%s)" % (
        len(EXPECTED) + len(C_HALVES), len(PRODUCTS), ", sources scanned" if sources is not None else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
