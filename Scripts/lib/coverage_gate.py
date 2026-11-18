"""The coverage gate (WP-003; COV-1…COV-6; CI gate 6 of §10.3).

    coverage_gate.py --report FILE [--report FILE]… [--mode aggregate|per-target|changed-files]…
                     [--root DIR] [--no-sources] [FILE …]

A report is the JSON that xccov prints for a result bundle, in either of its two shapes:

    xcrun xccov view --report  --json <bundle>.xcresult     totals per file
    xcrun xccov view --archive --json <bundle>.xcresult     every line of every file

Several reports are merged file by file: line by line where both carry lines, otherwise the
better-covered one wins (a device run merged with a simulator run, COV-3). Xcode links a
package target into every test bundle that uses it, so one source file appears under several
of xccov's targets; it is counted once.

Modes (default: aggregate and per-target):
    aggregate       all production targets together        ≥ 97.5 %   (COV-2)
    per-target      each production target                 ≥ 95 %     (COV-2)
    changed-files   each file named after the options, or one per line on standard input when
                    none is named                          ≥ 97.5 %   (COV-3)

The denominator (COV-4, COV-6): the production targets under Sources/. Tests, the Examples
project, benchmarks, ZTronDSPTesting and CZTronDSPTesting are outside it; Metal shaders cannot
be instrumented. A line marked `// coverage:ignore(<reason>)` leaves the denominator when the
tests do not execute it; a mark on a line of its own covers the branch below it. A mark without
a reason, a mark that excuses nothing, and marks that add up to 0.5 % of the production lines
or more each fail the gate. Marks are read against the per-line report.

Exit status: 0 pass, 1 fail, 2 usage error, 3 nothing to measure (no executable production line).
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import source_scan as scan  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

PRODUCTION = ("CZTronDSP", "ZTronDSPCore", "ZTronDSPDesign", "ZTronDSPMetal", "ZTronDSPAnalysis", "ZTronDSPIO", "ZTronDSPUI", "ZTronDSP")
TEST_SUPPORT = ("ZTronDSPTesting", "CZTronDSPTesting")
THRESHOLDS = {"aggregate": (975, 1000), "per-target": (95, 100), "changed-files": (975, 1000)}
IGNORE_CAP = (5, 1000)      # below 0.5 % of the production lines
MARK = re.compile(r"//\s*coverage:ignore\(([^)\n]*)\)")
SOURCE_SUFFIXES = (".swift", ".c", ".m", ".mm", ".h")


class FileCoverage:
    def __init__(self, relative):
        self.relative = relative
        self.lines = None        # {line: execution count} for executable lines, when a report carries lines
        self.executable = 0
        self.covered = 0
        self.ignored = 0

    @property
    def target(self):
        return self.relative.split("/")[1]

    def absorb_lines(self, lines):
        if self.lines is None:
            self.lines = {}
        for number, count in lines.items():
            self.lines[number] = max(self.lines.get(number, 0), count)
        self.executable = len(self.lines)
        self.covered = sum(1 for count in self.lines.values() if count > 0)

    def absorb_totals(self, executable, covered):
        if self.lines is not None:
            return                               # line data is exact; totals add nothing
        if (covered, -executable) > (self.covered, -self.executable) or self.executable == 0:
            self.executable, self.covered = executable, covered


def unprivate(path):
    return path[len("/private"):] if path.startswith("/private/") else path


def relative_path(path, root):
    """The path under the package root, or None when the file is not part of the package."""
    path = unprivate(path.replace(os.sep, "/"))
    if root:
        prefix = unprivate(os.path.abspath(root)).rstrip("/") + "/"
        if path.startswith(prefix):
            return path[len(prefix):]
    if not path.startswith("/"):
        return path
    known = "|".join(PRODUCTION + TEST_SUPPORT)
    match = re.search(r"/(Sources/(?:%s)/.*)$" % known, path)
    if match:
        return match.group(1)
    match = re.search(r"/((?:Tests|Examples|Benchmarks)/.*)$", path)
    return match.group(1) if match else None


def is_production(relative):
    if relative is None or relative.endswith(".metal"):
        return False
    parts = relative.split("/")
    return len(parts) >= 3 and parts[0] == "Sources" and parts[1] in PRODUCTION


def read_reports(paths, root):
    files = {}

    def entry(path):
        relative = relative_path(path, root)
        if not is_production(relative):
            return None
        return files.setdefault(relative, FileCoverage(relative))

    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                data = json.load(handle)
        except (OSError, ValueError) as error:
            raise SystemExit2("cannot read the report %s: %s" % (path, error))
        if isinstance(data, dict) and isinstance(data.get("targets"), list):
            for target in data["targets"]:
                for item in target.get("files", []):
                    coverage = entry(item.get("path", ""))
                    if coverage is not None:
                        coverage.absorb_totals(int(item.get("executableLines", 0)), int(item.get("coveredLines", 0)))
        elif isinstance(data, dict) and all(isinstance(value, list) for value in data.values()):
            for file_path, lines in data.items():
                coverage = entry(file_path)
                if coverage is None:
                    continue
                coverage.absorb_lines({int(line["line"]): int(line.get("executionCount", 0))
                                       for line in lines if line.get("isExecutable")})
        else:
            raise SystemExit2("%s is neither `xccov view --report --json` nor `xccov view --archive --json` output" % path)
    return files


class SystemExit2(Exception):
    pass


def marks_in(path):
    """[(lines the mark covers, reason, line of the mark)] for one source file.

    A mark at the end of a line covers that line. A mark on a line of its own covers the next
    line of code and, when that line opens a block, the block down to its closing brace: an
    unreachable defensive branch is marked once, above it.
    """
    with open(path, encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    lines = text.split("\n")
    masked = scan.mask(path, text).split("\n")
    found = []
    for index, line in enumerate(lines):
        match = MARK.search(line)
        if not match:
            continue
        if line[:match.start()].strip():
            found.append(([index + 1], match.group(1).strip(), index + 1))
            continue
        cursor = index + 1
        while cursor < len(lines) and not masked[cursor].strip():
            cursor += 1
        if cursor >= len(lines):
            found.append(([], match.group(1).strip(), index + 1))
            continue
        covered, depth = [cursor + 1], masked[cursor].count("{") - masked[cursor].count("}")
        if masked[cursor].rstrip().endswith("{"):
            while depth > 0 and cursor + 1 < len(lines):
                cursor += 1
                covered.append(cursor + 1)
                depth += masked[cursor].count("{") - masked[cursor].count("}")
        found.append((covered, match.group(1).strip(), index + 1))
    return found


def apply_marks(files, root, problems):
    """Takes marked, unexecuted lines out of the denominator. Returns how many it took out."""
    total = 0
    sources = os.path.join(root, "Sources")
    for target in PRODUCTION:
        directory = os.path.join(sources, target)
        for folder, names, filenames in os.walk(directory):
            names.sort()
            for filename in sorted(filenames):
                if not filename.endswith(SOURCE_SUFFIXES):
                    continue
                path = os.path.join(folder, filename)
                relative = os.path.relpath(path, root).replace(os.sep, "/")
                marks = marks_in(path)
                if not marks:
                    continue
                coverage = files.get(relative)
                for covered_lines, reason, mark_line in marks:
                    where = "%s:%d" % (relative, mark_line)
                    if not reason:
                        problems.append("%s: `// coverage:ignore()` gives no reason (COV-4)" % where)
                        continue
                    if coverage is None:
                        problems.append("%s: a coverage:ignore mark in a file the report does not hold" % where)
                        continue
                    if coverage.lines is None:
                        problems.append("%s: coverage:ignore marks need the per-line report (`xcrun xccov view --archive --json`, or --xcresult)" % where)
                        continue
                    excused = [line for line in covered_lines if coverage.lines.get(line, 1) == 0]
                    if not excused:
                        problems.append("%s: the mark excuses nothing: every line it covers is executed by the tests or is not executable; remove it (COV-4)" % where)
                        continue
                    for line in excused:
                        del coverage.lines[line]
                    coverage.executable -= len(excused)
                    coverage.ignored += len(excused)
                    total += len(excused)
    return total


DECLARATION_STARTS = {
    "func", "var", "let", "init", "deinit", "case", "typealias", "associatedtype", "subscript", "static", "class",
    "struct", "enum", "protocol", "extension", "public", "private", "internal", "fileprivate", "open", "package",
    "mutating", "nonmutating", "import", "@", "#", "}"}


def has_bodies(path):
    """Whether a source file holds a function body, that is, something that can execute.

    A protocol's requirements have no bodies, so a file of protocols, empty types and type
    aliases answers no: xccov rightly leaves such a file out of its report.
    """
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()
    except OSError:
        return False
    masked = scan.mask(path, text)
    if not path.endswith(".swift"):
        # `)` then `{`, with nothing but attribute macros between them: a function's body.
        return bool(re.search(r"\)\s*(?:[A-Za-z_]\w*(?:\([^()]*\))?\s*)*\{", masked))
    tokens = [token for token, _ in scan.tokens(masked)]
    for index, token in enumerate(tokens):
        if token not in ("func", "init", "deinit", "subscript"):
            continue
        cursor, depth, seen_parameters = index + 1, 0, token == "deinit"
        while cursor < len(tokens):
            word = tokens[cursor]
            if word in ("(", "[", "<"):
                depth += 1
            elif word in (")", "]", ">"):
                depth -= 1
                if depth == 0 and word == ")":
                    seen_parameters = True
            elif depth == 0 and word == "{":
                if seen_parameters:
                    # `{ get }` and `{ get set }` after a subscript are a requirement, not a body.
                    inside, closing = [], cursor + 1
                    while closing < len(tokens) and tokens[closing] != "}":
                        if tokens[closing] != "\n":
                            inside.append(tokens[closing])
                        closing += 1
                    if not (token == "subscript" and inside and all(item in ("get", "set", "async", "throws", "mutating", "nonmutating") for item in inside)):
                        return True
                break
            elif depth == 0 and seen_parameters and word in DECLARATION_STARTS:
                break
            cursor += 1
    return False


def target_has_bodies(root, target):
    directory = os.path.join(root, "Sources", target)
    for folder, names, filenames in os.walk(directory):
        names.sort()
        for filename in sorted(filenames):
            if filename.endswith((".swift", ".c", ".m", ".mm")) and has_bodies(os.path.join(folder, filename)):
                return True
    return False


def percent(covered, executable):
    return "%.2f %%" % (100.0 * covered / executable) if executable else "no executable lines"


def meets(covered, executable, threshold):
    return executable == 0 or covered * threshold[1] >= executable * threshold[0]


def main(arguments):
    reports, modes, root, changed, use_sources = [], [], ROOT, [], True
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("--report", "--mode", "--root") and index + 1 < len(arguments):
            index += 1
            if argument == "--report":
                reports.append(arguments[index])
            elif argument == "--mode":
                if arguments[index] not in THRESHOLDS:
                    print("coverage-gate: there is no mode %s" % arguments[index], file=sys.stderr)
                    return 2
                modes.append(arguments[index])
            else:
                root = arguments[index]
        elif argument == "--no-sources":
            use_sources = False
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif argument == "--":
            changed.extend(arguments[index + 1:])
            break
        elif argument.startswith("-"):
            print("coverage-gate: unknown option %s" % argument, file=sys.stderr)
            return 2
        else:
            changed.append(argument)
        index += 1
    if not reports:
        print("coverage-gate: give at least one --report (xccov JSON)", file=sys.stderr)
        return 2
    modes = modes or ["aggregate", "per-target"]
    if "changed-files" in modes and not changed:
        changed = [line.strip() for line in sys.stdin.read().split("\n") if line.strip()]
    if changed and "changed-files" not in modes:
        print("coverage-gate: files were named but --mode changed-files was not asked for", file=sys.stderr)
        return 2

    try:
        files = read_reports(reports, root)
    except SystemExit2 as error:
        print("coverage-gate: %s" % error, file=sys.stderr)
        return 2

    problems = []
    have_sources = use_sources and os.path.isdir(os.path.join(root, "Sources"))
    before = sum(coverage.executable for coverage in files.values())
    if before == 0:
        print("coverage-gate: the report holds no executable line of a production target; nothing to measure")
        return 3

    ignored = apply_marks(files, root, problems) if have_sources else 0
    if not have_sources:
        print("coverage-gate: note: no sources under %s; `// coverage:ignore` marks were not read" % root)
    if ignored * IGNORE_CAP[1] >= before * IGNORE_CAP[0]:
        problems.append("%d lines are marked coverage:ignore, %.2f %% of %d production lines; COV-4 keeps them below 0.50 %%" % (
            ignored, 100.0 * ignored / before, before))
    elif ignored:
        print("coverage-gate: %d line%s marked coverage:ignore (%.2f %% of the production lines, below 0.50 %%)" % (
            ignored, "" if ignored == 1 else "s", 100.0 * ignored / before))

    if "aggregate" in modes:
        covered = sum(c.covered for c in files.values())
        executable = sum(c.executable for c in files.values())
        ok = meets(covered, executable, THRESHOLDS["aggregate"])
        print("coverage-gate: aggregate      %s (%d of %d lines), needs 97.50 %%: %s" % (percent(covered, executable), covered, executable, "ok" if ok else "FAIL"))
        if not ok:
            problems.append("aggregate coverage is %s, below 97.50 %% (COV-2)" % percent(covered, executable))

    if "per-target" in modes:
        for target in PRODUCTION:
            members = [c for c in files.values() if c.target == target]
            covered = sum(c.covered for c in members)
            executable = sum(c.executable for c in members)
            unmeasured = executable == 0 and not members and have_sources and target_has_bodies(root, target)
            ok = meets(covered, executable, THRESHOLDS["per-target"]) and not unmeasured
            print("coverage-gate: %-16s %s (%d of %d lines), needs 95.00 %%: %s" % (
                target, "not measured" if unmeasured else percent(covered, executable), covered, executable, "ok" if ok else "FAIL"))
            if unmeasured:
                problems.append("%s has code and the report holds none of it: was it built with coverage?" % target)
            elif not ok:
                problems.append("%s is at %s, below 95.00 %% (COV-2)" % (target, percent(covered, executable)))

    if "changed-files" in modes:
        for name in changed:
            relative = relative_path(name if os.path.isabs(name) else os.path.join(root, name), root) or name
            if not is_production(relative):
                print("coverage-gate: %-50s outside the denominator (COV-6)" % relative)
                continue
            coverage = files.get(relative)
            if coverage is None:
                # xccov lists every file that holds an executable line. A file it leaves out holds
                # none, unless its whole target is missing from the report.
                path = os.path.join(root, relative)
                target = relative.split("/")[1]
                target_measured = any(c.target == target for c in files.values())
                if have_sources and not os.path.isfile(path):
                    problems.append("%s does not exist" % relative)
                elif have_sources and not target_measured and has_bodies(path):
                    problems.append("%s has code and the report holds nothing of %s: was it built with coverage?" % (relative, target))
                else:
                    print("coverage-gate: %-50s no executable lines" % relative)
                continue
            ok = meets(coverage.covered, coverage.executable, THRESHOLDS["changed-files"])
            print("coverage-gate: %-50s %s (%d of %d lines), needs 97.50 %%: %s" % (
                relative, percent(coverage.covered, coverage.executable), coverage.covered, coverage.executable, "ok" if ok else "FAIL"))
            if not ok:
                problems.append("%s is at %s, below 97.50 %% (COV-3)" % (relative, percent(coverage.covered, coverage.executable)))

    for problem in problems:
        print("coverage-gate: FAIL: " + problem)
    if problems:
        return 1
    print("coverage-gate: pass (%s)" % ", ".join(modes))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
