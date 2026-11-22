"""The runner of the golden-vector generators (WP-007, STG-2; CI gate 7 of §10.3).

    golden_runner.py [--only NAME]…                 run the generators; rewrite the manifest
    golden_runner.py --check [--strict]             verify the manifest's hashes; nothing is run
    golden_runner.py --reproduce [--only NAME]… [--tolerance T]
                                                    run the generators in a scratch copy of the tree
                                                    and compare with what is committed
    golden_runner.py --octave                       run every golden MATLAB script under GNU Octave
    Common option: --root DIR (a tree that holds Tests/Golden; default: the package).

A generator is every Tests/Golden/generators/[a-z]*.py; a file whose name starts with an
underscore is a helper (_oracle.py loads the pinned oracles, _golden.py writes the vectors).
Each is run with this Python from that folder and writes into Tests/<Target>/Golden/. A
generator that also writes a file elsewhere names it in a module-level list of paths relative
to the package:

    OUTPUTS = ["Tests/CZTronDSPTests/KernelFixtures.swift"]

Scripts/generate-stress-fixtures.py, which writes Sources/ZTronDSPTesting/StressFixtureData.swift,
is run as one more generator.

The manifest, Tests/Golden/manifest.json, records for every generator the SHA-256 of its source
and of each file it wrote: what changed in a Golden folder during its run (*.json, *.f32,
*.f64 and whatever else it puts there; README.txt is not a vector), and its OUTPUTS.

Running refuses to start when an installed oracle differs from its pin in
Tests/Golden/generators/requirements.txt. NumPy, SciPy and librosa must be pinned there, and are
read as a generator loads them, through _oracle.installed() (librosa after the SciPy stand-ins);
a further pin is read from the installed package's metadata. A generator that stops because a
pinned oracle is not installed is recorded as pending: --check reports it loudly and fails on it
under --strict.

The golden MATLAB scripts (every *.m in a Golden folder: the exports of §6.14 and the writer's
own script) are held, by --check, to the static check of Scripts/lib/matlab_check.py (MAT-2:
balanced, terminated, defined before use, rows of equal length, the commands of MAT-2 only).
--octave runs each under GNU Octave for real (WP-910): `octave --no-gui --quiet --norc
--no-history`, with QT_QPA_PLATFORM=offscreen, in a scratch folder, one process per script; the
runner sets the default figure visibility off and then sources the script unchanged, so every
plot command executes and draws, unseen. A script passes when Octave exits 0, prints no error and
no warning, reaches the end, and leaves the figure the static check says the script draws: per
axes its lines, stems and images, scales, grid, hold state, labels and title, and the colorbars.
Without Octave on the PATH the run is skipped, loudly, with exit status 3.

Exit status: 0 done or consistent, 1 a generator failed, the check found drift or a script failed
under Octave, 2 usage error or a refused run, 3 pending generators under --strict, or no Octave
for --octave.
"""

import ast
import hashlib
import importlib.metadata
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import matlab_check  # noqa: E402

PACKAGE_ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
VECTOR_SUFFIXES = (".json", ".f32", ".f64")
SCRIPT_SUFFIX = ".m"                 # a golden MATLAB script (§6.14): listed like a vector, and checked
NOT_VECTORS = ("README.txt",)
ORACLES = ("numpy", "scipy", "librosa")  # pinned always, read through _oracle.installed()
REQUIRED = ("numpy", "scipy")             # every generator loads these; librosa may be absent (pending)
# Generators that live outside Tests/Golden/generators: (script, the files it writes).
EXTRA_GENERATORS = (("Scripts/generate-stress-fixtures.py", ("Sources/ZTronDSPTesting/StressFixtureData.swift",)),)
NOT_COPIED = shutil.ignore_patterns(".build", ".git", ".swiftpm", "DerivedData", "*.xcresult", "__pycache__", ".venv")


class Refused(Exception):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


class Tree:
    def __init__(self, root):
        self.root = os.path.abspath(root)
        self.generators_directory = os.path.join(self.root, "Tests", "Golden", "generators")
        self.manifest_path = os.path.join(self.root, "Tests", "Golden", "manifest.json")
        self.requirements = os.path.join(self.generators_directory, "requirements.txt")

    def relative(self, path):
        return os.path.relpath(path, self.root).replace(os.sep, "/")

    def absolute(self, relative):
        return os.path.join(self.root, *relative.split("/"))

    def pins(self):
        pins = {}
        if not os.path.isfile(self.requirements):
            raise Refused("there is no %s" % self.relative(self.requirements))
        with open(self.requirements, encoding="utf-8") as handle:
            for raw in handle:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                match = re.match(r"^([A-Za-z0-9_.-]+)==([A-Za-z0-9_.+!-]+)$", line)
                if not match:
                    raise Refused("%s: '%s' is not a pin of the form name==version" % (self.relative(self.requirements), line))
                pins[match.group(1).lower()] = match.group(2)
        return pins

    def declared_outputs(self, path):
        """The module-level OUTPUTS of a generator, read without running it."""
        with open(path, encoding="utf-8") as handle:
            try:
                tree = ast.parse(handle.read(), filename=path)
            except SyntaxError as error:
                raise Refused("%s does not parse: %s" % (self.relative(path), error))
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id == "OUTPUTS":
                try:
                    value = ast.literal_eval(node.value)
                except ValueError:
                    raise Refused("%s: OUTPUTS is not a literal list of paths" % self.relative(path))
                if isinstance(value, str):
                    value = [value]
                if not all(isinstance(item, str) and item and not item.startswith("/") and ".." not in item.split("/") for item in value):
                    raise Refused("%s: OUTPUTS holds paths relative to the package, without '..'" % self.relative(path))
                return list(value)
        return None

    def generators(self):
        """[{name, path, source (relative), outputs (declared), directory (to run from)}], in a fixed order."""
        found = []
        if os.path.isdir(self.generators_directory):
            for name in sorted(os.listdir(self.generators_directory)):
                if not re.match(r"^[a-z][A-Za-z0-9_]*\.py$", name):
                    continue
                path = os.path.join(self.generators_directory, name)
                found.append({"name": name[:-3], "path": path, "source": self.relative(path),
                              "outputs": self.declared_outputs(path) or [], "directory": self.generators_directory})
        for script, outputs in EXTRA_GENERATORS:
            path = self.absolute(script)
            if os.path.isfile(path):
                found.append({"name": os.path.basename(script)[:-3], "path": path, "source": script,
                              "outputs": self.declared_outputs(path) or list(outputs), "directory": self.root})
        names = [generator["name"] for generator in found]
        for name in names:
            if names.count(name) > 1:
                raise Refused("two generators are named %s" % name)
        return found

    def golden_files(self):
        """Every file in a Golden folder of a test target, relative to the tree, README.txt apart."""
        found = []
        tests = os.path.join(self.root, "Tests")
        if not os.path.isdir(tests):
            return found
        for target in sorted(os.listdir(tests)):
            folder = os.path.join(tests, target, "Golden")
            if not os.path.isdir(folder) or target in ("Golden", "Fixtures", "CompileFixtures"):
                continue
            for directory, names, files in os.walk(folder):
                names.sort()
                for name in sorted(files):
                    if name in NOT_VECTORS or name.startswith("."):
                        continue
                    found.append(self.relative(os.path.join(directory, name)))
        return found

    def read_manifest(self):
        manifest = {"pins": {}, "generators": [], "pending": []}
        if os.path.isfile(self.manifest_path):
            with open(self.manifest_path, encoding="utf-8") as handle:
                manifest.update(json.load(handle))
        return manifest

    def write_manifest(self, manifest):
        manifest["generators"].sort(key=lambda entry: entry["generator"])
        manifest["pending"].sort(key=lambda entry: entry["generator"])
        for entry in manifest["generators"]:
            entry["outputs"].sort(key=lambda item: item["path"])
        os.makedirs(os.path.dirname(self.manifest_path), exist_ok=True)
        with open(self.manifest_path, "w", encoding="utf-8") as handle:
            json.dump({key: manifest[key] for key in ("pins", "generators", "pending")}, handle, indent=1, sort_keys=True)
            handle.write("\n")


def installed_oracles(tree):
    """Versions of NumPy, SciPy and librosa as the generators will see them (librosa None when it
    is not installed), and the stand-ins in use."""
    probe = ("import json, sys\nsys.path.insert(0, %r)\nimport _oracle\n"
             "print(json.dumps({'versions': _oracle.installed(), 'replaced': list(_oracle.replaced)}))\n" % tree.generators_directory)
    result = subprocess.run([sys.executable, "-c", probe], capture_output=True, text=True)
    if result.returncode != 0:
        raise Refused("the oracles cannot be loaded through Tests/Golden/generators/_oracle.py:\n" + result.stderr.strip())
    return json.loads(result.stdout.strip().split("\n")[-1])


def check_pins(tree):
    """Refuses when an installed oracle differs from its pin. Returns the pins."""
    pins = tree.pins()
    state = installed_oracles(tree)
    loaded = []
    for name in ORACLES:
        if name not in pins:
            raise Refused("%s is not pinned in %s" % (name, tree.relative(tree.requirements)))
        version = state["versions"].get(name)
        if version is None and name not in REQUIRED:
            loaded.append("%s not installed" % name)
            continue
        if version != pins[name]:
            raise Refused("%s %s is installed and %s is pinned: the vectors would not be the committed ones. "
                          "Install the pinned version, or change the pin and regenerate everything" % (name, version, pins[name]))
        loaded.append("%s %s" % (name, version))
    others = []
    for name in sorted(set(pins) - set(ORACLES)):
        try:
            version = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            others.append("%s not installed" % name)
            continue
        if version != pins[name]:
            raise Refused("%s %s is installed and %s is pinned" % (name, version, pins[name]))
        others.append("%s %s" % (name, version))
    print("golden: oracles %s" % ", ".join(loaded + others))
    if state["replaced"]:
        print("golden: stand-ins are in place of %d SciPy extensions this host cannot load (no oracle function reaches them):" % len(state["replaced"]))
        for name in state["replaced"]:
            print("golden:   %s" % name)
    return pins


def snapshot(tree, generator):
    """{relative path: (modification time, size)} of what a generator may write."""
    state = {}
    for relative in tree.golden_files() + generator["outputs"]:
        path = tree.absolute(relative)
        if os.path.isfile(path):
            status = os.stat(path)
            state[relative] = (status.st_mtime_ns, status.st_size)
    return state


def run_generator(tree, generator, pins):
    """Runs one generator in its tree. Returns (outputs written, error, name of a missing oracle)."""
    before = snapshot(tree, generator)
    result = subprocess.run([sys.executable, generator["path"]], cwd=generator["directory"], capture_output=True, text=True)
    if result.returncode != 0:
        missing = re.search(r"ModuleNotFoundError: No module named '([A-Za-z0-9_]+)", result.stderr)
        if missing:
            module = missing.group(1).lower()
            for pin in pins:
                if pin.replace("-", "_") == module:
                    return [], None, pin
        tail = "\n".join((result.stderr.strip() or result.stdout.strip() or "it exited with status %d" % result.returncode).split("\n")[-6:])
        return [], tail, None
    after = snapshot(tree, generator)
    written = {relative for relative, state in after.items() if before.get(relative) != state}
    absent = [relative for relative in generator["outputs"] if relative not in after]
    if absent:
        return [], "it declares OUTPUTS that it did not write: %s" % ", ".join(absent), None
    written |= set(generator["outputs"])
    if not written:
        return [], "it wrote nothing into a Golden folder and declares no OUTPUTS", None
    return sorted(written), None, None


def selected(generators, only):
    if not only:
        return generators
    names = {generator["name"] for generator in generators}
    for name in only:
        if name not in names:
            raise Refused("there is no generator named %s" % name)
    return [generator for generator in generators if generator["name"] in only]


def generate(tree, only):
    generators = tree.generators()
    chosen = selected(generators, only)
    pins = check_pins(tree)
    manifest = tree.read_manifest()
    manifest["pins"] = pins
    known = {generator["name"] for generator in generators}
    manifest["generators"] = [entry for entry in manifest["generators"] if entry["generator"] in known]
    manifest["pending"] = [entry for entry in manifest["pending"] if entry["generator"] in known]
    failed = 0
    for generator in chosen:
        name = generator["name"]
        outputs, error, missing_oracle = run_generator(tree, generator, pins)
        if missing_oracle:
            if any(entry["generator"] == name for entry in manifest["generators"]):
                print("golden: SKIPPED %s: %s is not installed; its committed vectors were kept as they are" % (name, missing_oracle))
            else:
                manifest["pending"] = [entry for entry in manifest["pending"] if entry["generator"] != name]
                manifest["pending"].append({"generator": name, "source": generator["source"], "reason": "%s is not installed" % missing_oracle})
                print("golden: PENDING %s: %s is not installed; no vectors were written" % (name, missing_oracle))
            continue
        if error:
            print("golden: FAILED %s:" % name)
            for line in error.split("\n"):
                print("golden:   " + line)
            failed += 1
            continue
        manifest["generators"] = [entry for entry in manifest["generators"] if entry["generator"] != name]
        manifest["pending"] = [entry for entry in manifest["pending"] if entry["generator"] != name]
        manifest["generators"].append({
            "generator": name, "source": generator["source"], "sourceSha256": sha256(generator["path"]),
            "outputs": [{"path": relative, "sha256": sha256(tree.absolute(relative))} for relative in outputs]})
        print("golden: %s: %s" % (name, ", ".join(outputs) if len(outputs) <= 3 else "%d files, %s … %s" % (len(outputs), outputs[0], outputs[-1])))

    owners = {}
    for entry in manifest["generators"]:
        for item in entry["outputs"]:
            owners.setdefault(item["path"], []).append(entry["generator"])
    for path, names in sorted(owners.items()):
        if len(names) > 1:
            print("golden: FAILED: %s is written by more than one generator: %s" % (path, ", ".join(sorted(names))))
            failed += 1
    if not only:
        for relative in tree.golden_files():
            if relative.endswith(VECTOR_SUFFIXES + (SCRIPT_SUFFIX,)) and relative not in owners:
                print("golden: FAILED: %s was written by no generator; remove it, or restore the generator it came from" % relative)
                failed += 1
    tree.write_manifest(manifest)
    files = sum(len(entry["outputs"]) for entry in manifest["generators"])
    print("golden: manifest written: %d file%s of %d generator%s, %d pending" % (
        files, "" if files == 1 else "s", len(manifest["generators"]), "" if len(manifest["generators"]) == 1 else "s", len(manifest["pending"])))
    return 1 if failed else 0


def check(tree, strict):
    problems = []
    if not os.path.isfile(tree.manifest_path):
        print("golden: there is no %s; run Scripts/golden.sh" % tree.relative(tree.manifest_path))
        return 1
    manifest = tree.read_manifest()
    pins = tree.pins()
    if manifest["pins"] != pins:
        problems.append("the pins of %s (%s) are not the ones the manifest recorded (%s): regenerate the vectors" % (
            tree.relative(tree.requirements), json.dumps(pins, sort_keys=True), json.dumps(manifest["pins"], sort_keys=True)))

    generators = {generator["name"]: generator for generator in tree.generators()}
    listed, recorded = {}, set()
    for entry in manifest["generators"]:
        name = entry["generator"]
        recorded.add(name)
        generator = generators.get(name)
        if generator is None:
            problems.append("the manifest lists files of %s, and there is no such generator (%s)" % (name, entry.get("source", "?")))
        else:
            if sha256(generator["path"]) != entry.get("sourceSha256"):
                problems.append("%s changed after it was last run: run Scripts/golden.sh --only %s" % (generator["source"], name))
            for relative in generator["outputs"]:
                if relative not in [item["path"] for item in entry.get("outputs", [])]:
                    problems.append("%s declares the output %s, which the manifest does not list: run Scripts/golden.sh --only %s" % (generator["source"], relative, name))
        if not entry.get("outputs"):
            problems.append("the manifest lists no file for %s" % name)
        for item in entry.get("outputs", []):
            path = tree.absolute(item["path"])
            if item["path"] in listed:
                problems.append("%s is listed for both %s and %s" % (item["path"], listed[item["path"]], name))
            listed[item["path"]] = name
            if not os.path.isfile(path):
                problems.append("%s is listed in the manifest and does not exist" % item["path"])
            elif sha256(path) != item["sha256"]:
                problems.append("%s is not the file the manifest recorded (its SHA-256 differs)" % item["path"])
    pending = []
    for entry in manifest["pending"]:
        name = entry["generator"]
        recorded.add(name)
        if name not in generators:
            problems.append("the manifest lists %s as pending, and there is no such generator" % name)
        else:
            pending.append(entry)
    for name in sorted(set(generators) - recorded):
        problems.append("the generator %s (%s) is not in the manifest: run Scripts/golden.sh --only %s" % (name, generators[name]["source"], name))
    for relative in tree.golden_files():
        if relative.endswith(VECTOR_SUFFIXES) and relative not in listed:
            problems.append("%s is a vector file that the manifest does not list" % relative)
        elif relative.endswith(SCRIPT_SUFFIX) and relative not in listed:
            problems.append("%s is a golden MATLAB script that the manifest does not list: a generator writes it (STG-2)" % relative)
    scripts = matlab_scripts(tree)
    for relative in scripts:
        found, _ = matlab_check.check_file(tree.absolute(relative))
        problems += ["%s:%d: %s" % (relative, line, message) if line else "%s: %s" % (relative, message) for line, message in found]

    for entry in pending:
        print("golden: PENDING %s: %s — no vectors exist, and every test that needs them is not running" % (entry["generator"], entry.get("reason", "no reason recorded")))
    for problem in problems:
        print("golden: " + problem)
    if problems:
        print("golden: %d problem%s" % (len(problems), "" if len(problems) == 1 else "s"))
        return 1
    print("golden: %d file%s of %d generator%s match the manifest%s" % (
        len(listed), "" if len(listed) == 1 else "s", len(manifest["generators"]), "" if len(manifest["generators"]) == 1 else "s",
        "; %d pending" % len(pending) if pending else ""))
    if scripts:
        print("golden: %d golden MATLAB script%s pass the static check (Scripts/lib/matlab_check.py, MAT-2)" % (
            len(scripts), "" if len(scripts) == 1 else "s"))
    if pending and strict:
        print("golden: --strict: pending generators fail the check")
        return 3
    return 0


def matlab_scripts(tree):
    """The golden MATLAB scripts of the tree, relative to it."""
    return [relative for relative in tree.golden_files() if relative.endswith(SCRIPT_SUFFIX)]


# The two functions the Octave run puts on Octave's path, in a scratch folder: the first sources a
# script in a workspace of its own with the default figure visibility off, so that its plot
# commands execute and draw unseen; the second prints what the figures hold.
OCTAVE_FUNCTIONS = {
    "ztd_run.m": """function ztd_run (ztd_script)
  % Sources one golden script, unchanged, in a workspace of its own; its figures are drawn, unseen.
  set (0, 'defaultfigurevisible', 'off');
  source (ztd_script);
end
""",
    "ztd_figure_report.m": """function ztd_figure_report ()
  % Prints the figures the script left: per axes the lines, stems and images it holds, its scales,
  % grid, hold state, labels and title; per figure the colorbars.
  figures = findall (0, 'type', 'figure');
  printf ('ZTD-FIGURES\\t%d\\n', numel (figures));
  for f = reshape (figures, 1, [])
    bars = 0;
    for ax = reshape (findall (f, 'type', 'axes'), 1, [])
      if (strcmp (get (ax, 'tag'), 'colorbar'))
        bars += 1;
        continue;
      end
      children = allchild (ax);
      baselines = [];
      stems = 0;
      for child = reshape (children, 1, [])
        if (strcmp (get (child, 'type'), 'hggroup') && isprop (child, 'baseline'))
          stems += 1;
          baselines(end + 1) = get (child, 'baseline');
        end
      end
      lines = 0;
      images = 0;
      for child = reshape (children, 1, [])
        switch (get (child, 'type'))
          case 'line'
            lines += ! any (baselines == child);
          case 'image'
            images += 1;
        end
      end
      printf ('ZTD-PANEL\\t%d\\t%d\\t%d\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n', lines, stems, images, ...
              get (ax, 'xscale'), get (ax, 'yscale'), get (ax, 'xgrid'), get (ax, 'nextplot'), ...
              get (get (ax, 'xlabel'), 'string'), get (get (ax, 'ylabel'), 'string'), get (get (ax, 'title'), 'string'));
    end
    printf ('ZTD-COLORBARS\\t%d\\n', bars);
  end
end
""",
}
OCTAVE_OPTIONS = ("--no-gui", "--quiet", "--norc", "--no-history")
OCTAVE_DONE = "ZTD-OCTAVE-DONE"


def octave_text(text):
    """Text inside single quotes in Octave."""
    return "'" + text.replace("'", "''") + "'"


def octave_version(octave):
    try:
        result = subprocess.run([octave, "--version"], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return "of unknown version (%s)" % error
    first = result.stdout.strip().split("\n")[0] if result.stdout.strip() else ""
    match = re.search(r"version (\S+)", first)
    return match.group(1) if match else (first or "of unknown version")


def drawn_figure(output):
    """The figure as the report of ztd_figure_report gives it, in the form of matlab_check's model."""
    figures, bars, panels = None, 0, []
    for line in output.split("\n"):
        fields = line.rstrip("\r").split("\t")
        if fields[0] == "ZTD-FIGURES" and len(fields) == 2 and fields[1].isdigit():
            figures = int(fields[1])
        elif fields[0] == "ZTD-COLORBARS" and len(fields) == 2 and fields[1].isdigit():
            bars += int(fields[1])
        elif fields[0] == "ZTD-PANEL" and len(fields) == 11 and all(field.isdigit() for field in fields[1:4]):
            panels.append(tuple(int(field) for field in fields[1:4]) + tuple(fields[4:]))
    return {"figures": figures, "colorbars": bars, "panels": sorted(panels)}


def described(model):
    if not model["figures"]:
        return "no figure (the script plots nothing)"
    panels = model["panels"]
    counts = [(sum(panel[i] for panel in panels), name) for i, name in ((0, "line"), (1, "stem"), (2, "image"))]
    held = ", ".join("%d %s%s" % (count, name, "" if count == 1 else "s") for count, name in counts if count)
    return "%d figure: %d axes (%s), %d colorbar%s, labels, titles and scales as the script sets them" % (
        model["figures"], len(panels), held or "empty", model["colorbars"], "" if model["colorbars"] == 1 else "s")


def octave(tree):
    scripts = matlab_scripts(tree)
    binary = shutil.which("octave")
    if binary is None:
        print("golden: SKIPPED: GNU Octave is not installed (no octave on the PATH): the %d golden MATLAB script%s %s not run "
              "under Octave (brew install octave)" % (len(scripts), "" if len(scripts) == 1 else "s", "was" if len(scripts) == 1 else "were"))
        return 3
    if not scripts:
        print("golden: there is no golden MATLAB script to run under Octave")
        return 0
    environment = dict(os.environ)
    environment.setdefault("QT_QPA_PLATFORM", "offscreen")
    holder = tempfile.mkdtemp(prefix="ztd-octave-")
    failed = 0
    try:
        for name, text in OCTAVE_FUNCTIONS.items():
            with open(os.path.join(holder, name), "w", encoding="utf-8") as handle:
                handle.write(text)
        print("golden: GNU Octave %s (%s), once per script in a scratch folder: QT_QPA_PLATFORM=%s octave %s --eval "
              "\"addpath(<scratch>); ztd_run(<script>); ztd_figure_report (); printf ('%s\\n');\"" % (
                  octave_version(binary), binary, environment["QT_QPA_PLATFORM"], " ".join(OCTAVE_OPTIONS), OCTAVE_DONE))
        for relative in scripts:
            path = tree.absolute(relative)
            static, model = matlab_check.check_file(path)
            statement = "addpath (%s); ztd_run (%s); ztd_figure_report (); printf ('%s\\n');" % (
                octave_text(holder), octave_text(path), OCTAVE_DONE)
            reasons, details = [], []
            try:
                result = subprocess.run([binary] + list(OCTAVE_OPTIONS) + ["--eval", statement], cwd=holder, env=environment,
                                        capture_output=True, text=True, timeout=300)
            except subprocess.TimeoutExpired:
                reasons.append("Octave did not finish within 300 s")
                result = None
            if result is not None:
                errors = [line for line in result.stderr.split("\n") if re.match(r"^\s*(error|warning)\b", line, re.IGNORECASE)]
                if result.returncode != 0:
                    reasons.append("Octave exited with status %d" % result.returncode)
                if errors:
                    reasons.append("Octave reported %d error%s or warning%s" % (len(errors), "" if len(errors) == 1 else "s", "" if len(errors) == 1 else "s"))
                if OCTAVE_DONE not in result.stdout.split("\n"):
                    reasons.append("the run did not reach its end (%s was not printed)" % OCTAVE_DONE)
                if not reasons:
                    drawn = drawn_figure(result.stdout)
                    if drawn != model:
                        reasons.append("the figure Octave drew is not the one the script draws")
                        details += ["expected: " + line for line in matlab_check.model_lines(model)]
                        details += ["drawn:    " + line for line in matlab_check.model_lines(drawn)] if drawn["figures"] is not None else \
                            ["drawn:    no report of the figures"]
                details += ["stderr: " + line for line in result.stderr.strip().split("\n") if line.strip()][-12:]
            if static:
                details.append("the static check finds %d problem%s here (Scripts/golden.sh --check)" % (len(static), "" if len(static) == 1 else "s"))
            if reasons:
                failed += 1
                print("golden: FAILED under Octave: %s: %s" % (relative, "; ".join(reasons)))
            else:
                print("golden: ran under Octave: %s: exit 0, no error and no warning, %s" % (relative, described(model)))
            for line in details:
                print("golden:   " + line)
    finally:
        shutil.rmtree(holder, ignore_errors=True)
    print("golden: %d of %d golden MATLAB script%s ran under GNU Octave as %s" % (
        len(scripts) - failed, len(scripts), "" if len(scripts) == 1 else "s", "they draw" if len(scripts) != 1 else "it draws"))
    return 1 if failed else 0


def read_raw(path, kind):
    with open(path, "rb") as handle:
        data = handle.read()
    width, code = (8, "d") if kind == "f64" else (4, "f")
    if len(data) % width:
        raise ValueError("%s is not a whole number of %s values" % (path, kind))
    return list(struct.unpack("<%d%s" % (len(data) // width, code), data))


def flatten(value, directory):
    """A value of a vector file as a flat list of floats."""
    if isinstance(value, list):
        return [float(x) for x in value]
    if isinstance(value, dict) and "raw" in value:
        return read_raw(os.path.join(directory, value["raw"]), value["raw"].rsplit(".", 1)[-1])
    if isinstance(value, dict) and "re" in value:
        return [float(x) for x in value["re"]] + [float(x) for x in value["im"]]
    raise ValueError("a value is neither an array, a complex pair nor a raw file")


def compare_documents(committed_path, fresh_path, tolerance):
    """(worst relative deviation, problems) between a committed vector file and a fresh one."""
    with open(committed_path, encoding="utf-8") as handle:
        committed = json.load(handle)
    with open(fresh_path, encoding="utf-8") as handle:
        fresh = json.load(handle)
    problems, worst = [], 0.0
    if committed.get("oracle") != fresh.get("oracle"):
        problems.append("the oracle versions differ: %s committed, %s now" % (committed.get("oracle"), fresh.get("oracle")))
    names_committed = [c["name"] for c in committed.get("cases", [])]
    names_fresh = [c["name"] for c in fresh.get("cases", [])]
    if names_committed != names_fresh:
        problems.append("the cases differ: %d committed, %d now" % (len(names_committed), len(names_fresh)))
        return worst, problems
    for old, new in zip(committed["cases"], fresh["cases"]):
        if old["parameters"] != new["parameters"]:
            problems.append("case %s: the parameters differ" % old["name"])
        if sorted(old["values"]) != sorted(new["values"]):
            problems.append("case %s: the value keys differ" % old["name"])
            continue
        for key in sorted(old["values"]):
            a = flatten(old["values"][key], os.path.dirname(committed_path))
            b = flatten(new["values"][key], os.path.dirname(fresh_path))
            if len(a) != len(b):
                problems.append("case %s, %s: %d values committed, %d now" % (old["name"], key, len(a), len(b)))
                continue
            scale = max([abs(x) for x in a] + [1e-300])
            deviation = max([abs(x - y) for x, y in zip(a, b)] + [0.0]) / scale
            worst = max(worst, deviation)
            if deviation > tolerance:
                problems.append("case %s, %s: deviates by %.3g of its largest value (tolerance %.3g)" % (old["name"], key, deviation, tolerance))
    return worst, problems


def reproduce(tree, only, tolerance):
    chosen = selected(tree.generators(), only)
    pins = check_pins(tree)
    manifest = tree.read_manifest()
    entries = {entry["generator"]: entry for entry in manifest["generators"]}
    # What the tree holds before the run: a generator that writes through an absolute path
    # would change it, and the comparison below would then compare a file with itself.
    guarded = {}
    for relative in sorted(set(tree.golden_files()) | {item["path"] for entry in manifest["generators"] for item in entry["outputs"]}):
        if os.path.isfile(tree.absolute(relative)):
            guarded[relative] = sha256(tree.absolute(relative))

    holder = tempfile.mkdtemp(prefix="ztd-golden-")
    failed = 0
    try:
        scratch = Tree(os.path.join(holder, "tree"))
        shutil.copytree(tree.root, scratch.root, ignore=NOT_COPIED, symlinks=True)
        fresh_generators = {generator["name"]: generator for generator in scratch.generators()}
        for generator in chosen:
            name = generator["name"]
            if name not in entries:
                print("golden: FAILED %s: it has no committed files to compare with" % name)
                failed += 1
                continue
            outputs, error, missing_oracle = run_generator(scratch, fresh_generators[name], pins)
            if missing_oracle:
                print("golden: SKIPPED %s: %s is not installed; nothing was reproduced" % (name, missing_oracle))
                continue
            if error:
                print("golden: FAILED %s:" % name)
                for line in error.split("\n"):
                    print("golden:   " + line)
                failed += 1
                continue
            committed = sorted(item["path"] for item in entries[name]["outputs"])
            if outputs != committed:
                print("golden: FAILED %s: it now writes %s; committed are %s" % (name, ", ".join(outputs), ", ".join(committed)))
                failed += 1
                continue
            differing = [relative for relative in outputs if sha256(scratch.absolute(relative)) != sha256(tree.absolute(relative))]
            if not differing:
                print("golden: %s reproduces its committed files bit for bit" % name)
                continue
            problems, worst = [], 0.0
            documents = [relative for relative in outputs if relative.endswith(".json")]
            covered = set()
            for relative in documents:
                try:
                    deviation, found = compare_documents(tree.absolute(relative), scratch.absolute(relative), tolerance)
                except (ValueError, KeyError, OSError) as issue:
                    deviation, found = 0.0, ["%s cannot be compared: %s" % (relative, issue)]
                worst = max(worst, deviation)
                problems += ["%s: %s" % (relative, problem) for problem in found]
                covered.add(relative)
                with open(scratch.absolute(relative), encoding="utf-8") as handle:
                    for raw_name in re.findall(r'"raw"\s*:\s*"([^"]+)"', handle.read()):
                        covered.add(os.path.dirname(relative) + "/" + raw_name)
            for relative in differing:
                if relative not in covered:
                    problems.append("%s differs, and it is not a vector file that can be compared within a tolerance" % relative)
            if problems:
                print("golden: FAILED %s does not reproduce its committed files:" % name)
                for problem in problems:
                    print("golden:   " + problem)
                failed += 1
            else:
                print("golden: %s reproduces its committed vectors within %.3g of each array's largest value (not bit for bit)" % (name, worst))
        for relative, digest in sorted(guarded.items()):
            path = tree.absolute(relative)
            if os.path.isfile(path) and sha256(path) != digest:
                print("golden: FAILED: %s changed during the run: a generator wrote outside the tree it was run in" % relative)
                failed += 1
    finally:
        shutil.rmtree(holder, ignore_errors=True)
    return 1 if failed else 0


def main(arguments):
    mode, strict, only, root, tolerance = "generate", False, [], PACKAGE_ROOT, 1e-12
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--check":
            mode = "check"
        elif argument == "--reproduce":
            mode = "reproduce"
        elif argument == "--octave":
            mode = "octave"
        elif argument == "--strict":
            strict = True
        elif argument in ("--only", "--root", "--tolerance") and index + 1 < len(arguments):
            index += 1
            if argument == "--only":
                only.append(arguments[index])
            elif argument == "--root":
                root = arguments[index]
            else:
                try:
                    tolerance = float(arguments[index])
                except ValueError:
                    print("golden: --tolerance takes a number", file=sys.stderr)
                    return 2
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            print("golden: unknown argument %s" % argument, file=sys.stderr)
            return 2
        index += 1
    tree = Tree(root)
    if not os.path.isdir(tree.generators_directory):
        print("golden: there is no %s" % tree.generators_directory, file=sys.stderr)
        return 2
    try:
        if mode == "check":
            return check(tree, strict)
        if mode == "reproduce":
            return reproduce(tree, only, tolerance)
        if mode == "octave":
            return octave(tree)
        return generate(tree, only)
    except Refused as refusal:
        print("golden: refused: %s" % refusal, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
