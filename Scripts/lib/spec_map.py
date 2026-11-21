"""The map of the public API to the specification (WP-901a): Docs/API/spec-map.tsv.

    spec_map.py check --digests DIR [--map FILE] [--spec FILE] [--changes DIR] [--label NAME]

The map holds one line per entry, four columns separated by one tab: the module, the symbol, the
place that lists it, and a note. A symbol is spelt as the digests spell it (Docs/API/<Module>.txt):

    DSPEngine                          a top-level declaration of the module
    ztd_ring_create(_:_:_:)            (functions with their argument labels)
    DSPEngine.attach(_:to:)            a member of one of the module's own types
    extension Pipeline.gain(_:ramp:isActive:)
                                       a member the module adds to a type of another module
    reexport ZTronDSPCore              a module the facade re-exports

Overloads share their name, and so one line. The place is one of: a section of the specification
(`§5.11.1`), a rule or a row it defines (`VC-4`, `O-16`, `WP-204`, `F5`), Appendix A or one of its rows
(`App. A`, `App. A row 12`), or a change request (`CR-016`, `CR-016 item 3`). Lines starting with
`#` and empty lines are comments. The data lines are sorted by module, then by symbol (byte order).

The check fails on:
  1. a public symbol without a line: every top-level declaration of every digest, every member a
     module adds to a type it does not own, and every module the facade re-exports (no unlisted
     public symbol); the symbol is printed with its digest line;
  2. a line that names a symbol no digest holds (a stale line);
  3. a line whose place does not exist: a section, rule or row the specification does not have,
     or a change request (or an item of one) that is not in the changes folder;
  4. a line that is not four columns, names no place, repeats an entry or is out of order.

Exit status: 0 the map is complete and true, 1 a finding, 2 usage error.
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))
NOT_SYMBOLS = ("conformance", "inheritance")
MEMBER = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\.(.+)$")
EXTENDS = re.compile(r"\s+\[extends ([^\]]+)\]$")
RULE = re.compile(r"^[A-Z][A-Z0-9]*-?[0-9]+[a-z]?$")
SECTION = re.compile(r"^§([0-9]+(?:\.[0-9]+)*)$")
APPENDIX = re.compile(r"^App\. ([A-Z])(?: row ([0-9]+))?$")
CHANGE = re.compile(r"^(CR-[0-9]{3})(?: item ([0-9]+))?$")


class Digest:
    """The symbols one digest file holds."""

    def __init__(self, module):
        self.module = module
        self.required = {}    # symbol as the map spells it -> the digest line
        self.members = {}     # members of the module's own types: path -> line

    def add(self, line):
        kind = line.split(None, 1)[0]
        if kind in NOT_SYMBOLS:
            return
        if kind == "reexport":
            name = line.split(None, 1)[1].strip()
            self.required["reexport " + name] = line
            return
        head, separator, _ = line.partition(" : ")
        if not separator:
            return
        path = head.split(None, 1)[1].strip() if len(head.split(None, 1)) == 2 else ""
        if not path:
            return
        extended = EXTENDS.search(line)
        if extended and extended.group(1) != self.module:
            self.required.setdefault("extension " + path, line)
            return
        name_part = path.split("(", 1)[0]
        if MEMBER.match(name_part):
            self.members.setdefault(path, line)
        else:
            self.required.setdefault(path, line)

    def holds(self, symbol):
        return symbol in self.required or symbol in self.members


def read_digests(directory):
    """{module: Digest} for every <Module>.txt in `directory`."""
    digests = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".txt"):
            continue
        digest = Digest(name[:-4])
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            for raw in handle:
                line = raw.rstrip("\n")
                if line.strip() and not line.startswith("#"):
                    digest.add(line)
        digests[digest.module] = digest
    return digests


class Specification:
    """What a line may name: the headings, the defined rules and rows, Appendix A's rows."""

    def __init__(self, path):
        with open(path, encoding="utf-8") as handle:
            self.text = handle.read()
        lines = self.text.split("\n")
        self.sections, self.appendices, self.appendix_rows = set(), set(), {}
        current_appendix, header_seen = None, False
        for line in lines:
            if line.startswith("#"):
                heading = re.match(r"^#{1,6}\s+([0-9]+(?:\.[0-9]+)*)\.?\s", line)
                if heading:
                    self.sections.add(heading.group(1))
                appendix = re.match(r"^#{1,6}\s+Appendix ([A-Z])\b", line)
                current_appendix, header_seen = (appendix.group(1) if appendix else None), False
                if current_appendix:
                    self.appendices.add(current_appendix)
                    self.appendix_rows[current_appendix] = 0
                continue
            if current_appendix and line.startswith("|"):
                if not header_seen:
                    header_seen = True
                elif not re.match(r"^\|\s*:?-+", line):
                    self.appendix_rows[current_appendix] += 1
        self._defined = {}

    def defines(self, rule):
        if rule not in self._defined:
            escaped = re.escape(rule)
            bold = re.search(r"\*\*" + escaped + r"(?![\w-])", self.text)
            first_cell = re.search(r"(?m)^\|\s*(?:\*\*)?" + escaped + r"(?![\w-])", self.text)
            self._defined[rule] = bool(bold or first_cell)
        return self._defined[rule]


def change_request_items(path):
    """The item numbers a change request writes as `n.` at the start of a line, or `| n |`."""
    items = set()
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            match = re.match(r"^\s*([0-9]+)\.\s", line) or re.match(r"^\|\s*([0-9]+)\s*\|", line)
            if match:
                items.add(int(match.group(1)))
    return items


def place_problem(place, specification, changes):
    """None when the place exists; otherwise the sentence that says why it does not."""
    section = SECTION.match(place)
    if section:
        if section.group(1) in specification.sections:
            return None
        return "is listed at %s, a section the specification does not have" % place
    appendix = APPENDIX.match(place)
    if appendix:
        letter, row = appendix.group(1), appendix.group(2)
        if letter not in specification.appendices:
            return "is listed at %s, an appendix the specification does not have" % place
        if row is not None and not 1 <= int(row) <= specification.appendix_rows.get(letter, 0):
            return "is listed at %s, but Appendix %s has %d rows" % (place, letter, specification.appendix_rows.get(letter, 0))
        return None
    change = CHANGE.match(place)
    if change:
        number, item = change.group(1), change.group(2)
        path = os.path.join(changes, number + ".md")
        if not os.path.isfile(path):
            return "names %s, which is not in %s" % (number, display(changes))
        if item is not None and int(item) not in change_request_items(path):
            return "names item %s of %s, which %s does not have" % (item, number, number)
        return None
    if RULE.match(place):
        if specification.defines(place):
            return None
        return "is listed at %s, a rule or row the specification does not define" % place
    return "is listed at \"%s\", which is not a place: a section (§5.11.1), a rule or row (VC-4, WP-204), " \
           "App. A row N, or a change request (CR-016, CR-016 item 3)" % place


def display(path):
    path = os.path.abspath(path)
    return os.path.relpath(path, PACKAGE_ROOT) if path.startswith(PACKAGE_ROOT + os.sep) else path


def kind_of(place):
    """For the summary: `specification` or the change request's number."""
    change = CHANGE.match(place)
    return change.group(1) if change else "specification"


def check(digests_directory, map_path, spec_path, changes, label):
    findings, unlisted = [], []
    if not os.path.isdir(digests_directory):
        print("api-digest: there is no folder of digests %s" % digests_directory, file=sys.stderr)
        return 2
    if not os.path.isfile(map_path):
        print("api-digest: there is no map of the public API at %s (WP-901a)" % label)
        return 1
    if not os.path.isfile(spec_path):
        print("api-digest: there is no specification at %s" % spec_path, file=sys.stderr)
        return 2
    if not os.path.isdir(changes):
        print("api-digest: there is no folder of change requests %s" % changes, file=sys.stderr)
        return 2
    digests = read_digests(digests_directory)
    specification = Specification(spec_path)

    listed, previous, kinds, lines = set(), None, {}, 0
    with open(map_path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, start=1):
            line = raw.rstrip("\n")
            if not line.strip() or line.startswith("#"):
                continue
            where = "%s:%d" % (label, number)
            columns = line.split("\t")
            if len(columns) != 4:
                findings.append("%s: a line has four columns separated by tabs (module, symbol, where it is listed, note); "
                                "this one has %d" % (where, len(columns)))
                continue
            module, symbol, place, _ = (column.strip() for column in columns)
            lines += 1
            key = (module, symbol)
            if previous is not None and key < previous:
                findings.append("%s: %s %s is out of order: the map is sorted by module, then by symbol" % (where, module, symbol))
            if key in listed:
                findings.append("%s: %s %s has a line already" % (where, module, symbol))
            listed.add(key)
            previous = key if previous is None else max(previous, key)
            digest = digests.get(module)
            if digest is None:
                findings.append("%s: %s %s names a module that has no digest (a stale line)" % (where, module, symbol))
            elif not digest.holds(symbol):
                findings.append("%s: %s %s is in no digest (a stale line)" % (where, module, symbol))
            if not place:
                findings.append("%s: %s %s has no place where it is listed" % (where, module, symbol))
                continue
            problem = place_problem(place, specification, changes)
            if problem:
                findings.append("%s: %s %s %s" % (where, module, symbol, problem))
            else:
                kinds[kind_of(place)] = kinds.get(kind_of(place), 0) + 1

    for module, digest in sorted(digests.items()):
        for symbol, digest_line in sorted(digest.required.items()):
            if (module, symbol) not in listed:
                unlisted.append("api-digest: %s %s is public and the map does not list it:\n    %s" % (module, symbol, digest_line))

    for finding in findings:
        print("api-digest: " + finding)
    for finding in unlisted:
        print(finding)
    if unlisted:
        print("api-digest: %d public symbol%s without a line in %s: no public symbol goes unlisted (WP-901a)" % (
            len(unlisted), "" if len(unlisted) == 1 else "s", label))
    if findings or unlisted:
        return 1
    by_change = sum(count for kind, count in kinds.items() if kind != "specification")
    requests = len([k for k in kinds if k != "specification"])
    print("api-digest: %s lists every public symbol of %d digest%s in %d line%s (%d at the specification, %d at %d change request%s)" % (
        label, len(digests), "" if len(digests) == 1 else "s", lines, "" if lines == 1 else "s",
        kinds.get("specification", 0), by_change, requests, "" if requests == 1 else "s"))
    return 0


def main(arguments):
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if arguments else 2
    if arguments[0] != "check":
        print("api-digest: there is no command %s" % arguments[0], file=sys.stderr)
        return 2
    options = {"--digests": None, "--map": None, "--spec": os.path.join(PACKAGE_ROOT, "Docs", "Specification", "ZTronDSP-SPEC.md"),
               "--changes": os.path.join(PACKAGE_ROOT, "Docs", "Process", "changes"), "--label": None}
    index = 1
    while index < len(arguments):
        if arguments[index] in options and index + 1 < len(arguments):
            options[arguments[index]] = arguments[index + 1]
            index += 2
            continue
        print("api-digest: unknown argument %s" % arguments[index], file=sys.stderr)
        return 2
    if not options["--digests"]:
        print("api-digest: the map check needs --digests", file=sys.stderr)
        return 2
    map_path = options["--map"] or os.path.join(options["--digests"], "spec-map.tsv")
    return check(options["--digests"], map_path, options["--spec"], options["--changes"], options["--label"] or display(map_path))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
