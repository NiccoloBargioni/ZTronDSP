"""Reads the work packages of §12 and the traceability table of §2 from the specification.

Shared by the ledger generator (WP-008) and the mechanical cross-check (§13.1).
Nothing here edits the specification.
"""

import re
from dataclasses import dataclass, field

MILESTONE_HEADING = re.compile(r"^### (M\d) — (.+?)\s*$")
PACKAGE_TABLE_HEADER = re.compile(r"^\|\s*ID\s*\|\s*Package\s*\|\s*Dep\s*\|\s*Acceptance\s*\|\s*Lenses\s*\|\s*Tag\s*\|\s*$")
SINGLE_ID = re.compile(r"^WP-(\d{3})([a-z]?)$")
# "WP-905a…d": one row that stands for several packages.
SUFFIX_RANGE_ID = re.compile(r"^WP-(\d{3})([a-z])…([a-z])$")
# Any reference in running text: WP-201, WP-611a, WP-201…227, WP-611a…d, WP-428a…431d.
REFERENCE = re.compile(r"WP-(\d{3})([a-z]?)(?:…(?:WP-)?(\d{3})?([a-z]?))?")
LENSES = "NRATVS"
# Milestones whose packages "all" stands for (see resolve_dependencies).
ALL_MEANS = ("M0", "M1", "M2", "M3", "M4", "M5", "M6", "M7", "M8")


def key_of(package_id):
    """Orders identifiers as the document does: by number, then by suffix."""
    match = SINGLE_ID.match(package_id)
    return (int(match.group(1)), match.group(2))


def make_id(number, suffix=""):
    return "WP-%03d%s" % (int(number), suffix)


def split_row(line):
    """Splits one markdown table row into its cells.

    A pipe inside a code span, or escaped with a backslash, does not end a cell.
    """
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        text = text[:-1]
    cells, current, in_code, index = [], [], False, 0
    while index < len(text):
        character = text[index]
        if character == "\\" and index + 1 < len(text) and text[index + 1] == "|":
            current.append("|")
            index += 2
            continue
        if character == "`":
            in_code = not in_code
        if character == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(character)
        index += 1
    cells.append("".join(current).strip())
    return cells


@dataclass
class Package:
    id: str
    row_id: str          # the ID cell as written; differs from `id` for a row such as WP-905a…d
    milestone: str
    milestone_title: str
    title: str
    deps_raw: str
    acceptance: str
    lenses_raw: str
    tag: str
    line: int
    deps: list = field(default_factory=list)       # resolved identifiers, in document order
    dep_notes: list = field(default_factory=list)  # findings raised while resolving


@dataclass
class Specification:
    path: str
    lines: list
    packages: list            # one entry per package (a row such as WP-905a…d is expanded)
    rows: int                 # table rows read from the milestone tables of §12
    parse_findings: list      # (line, message)

    @property
    def by_id(self):
        return {package.id: package for package in self.packages}

    def ids_sorted(self):
        return sorted({package.id for package in self.packages}, key=key_of)

    def parts_of(self, base_id):
        """Identifiers that are suffixed parts of `base_id` (WP-306 → WP-306a, WP-306b, WP-306c)."""
        match = SINGLE_ID.match(base_id)
        if not match or match.group(2):
            return []
        number = int(match.group(1))
        return [i for i in self.ids_sorted() if key_of(i)[0] == number and key_of(i)[1] != ""]

    def between(self, first, last):
        low, high = key_of(first), key_of(last)
        return [i for i in self.ids_sorted() if low <= key_of(i) <= high]


def expand_id_cell(cell):
    """Returns the package identifiers one ID cell stands for, or None when it is malformed."""
    if SINGLE_ID.match(cell):
        return [cell]
    match = SUFFIX_RANGE_ID.match(cell)
    if match and match.group(2) <= match.group(3):
        number = match.group(1)
        return [make_id(number, chr(code)) for code in range(ord(match.group(2)), ord(match.group(3)) + 1)]
    return None


def read(path):
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")

    packages, findings, rows = [], [], 0
    milestone, milestone_title, in_table = None, None, False
    in_section_12 = False
    for number, line in enumerate(lines, start=1):
        if line.startswith("## "):
            in_section_12 = line.startswith("## 12.")
            milestone, in_table = None, False
            continue
        if not in_section_12:
            continue
        heading = MILESTONE_HEADING.match(line)
        if heading:
            milestone, milestone_title, in_table = heading.group(1), heading.group(2), False
            continue
        if line.startswith("### "):
            milestone, in_table = None, False
            continue
        if milestone is None:
            continue
        if PACKAGE_TABLE_HEADER.match(line):
            in_table = True
            continue
        if not in_table:
            continue
        if not line.startswith("|"):
            in_table = False
            continue
        if re.match(r"^\|\s*-+\s*\|", line):
            continue
        cells = split_row(line)
        if len(cells) != 6:
            findings.append((number, "row has %d cells, expected 6: %s" % (len(cells), line[:80])))
            continue
        rows += 1
        ids = expand_id_cell(cells[0])
        if ids is None:
            findings.append((number, "malformed package identifier '%s'" % cells[0]))
            continue
        for package_id in ids:
            packages.append(Package(
                id=package_id, row_id=cells[0], milestone=milestone, milestone_title=milestone_title,
                title=cells[1], deps_raw=cells[2], acceptance=cells[3], lenses_raw=cells[4],
                tag=cells[5], line=number))

    specification = Specification(path=path, lines=lines, packages=packages, rows=rows, parse_findings=findings)
    resolve_dependencies(specification)
    return specification


def resolve_reference(specification, number, suffix):
    """Resolves one identifier named somewhere. Returns (identifiers, note).

    A name that exists resolves to itself. A name that exists only as suffixed parts resolves to
    all of them, which is what WP-R4 prescribes for a retired identifier; the note says so. A
    suffixed name whose whole package exists resolves to that package, with a note. Anything
    else resolves to nothing: it is dangling.
    """
    package_id = make_id(number, suffix)
    known = specification.by_id
    if package_id in known:
        return [package_id], None
    parts = specification.parts_of(package_id)
    if parts:
        return parts, "%s exists only as its parts %s…%s" % (package_id, parts[0], parts[-1][-1])
    whole = make_id(number)
    if suffix and whole in known:
        # A part of a package that §12 keeps whole: the name of a split that has not happened.
        return [whole], "%s is a part of %s that §12 does not define" % (package_id, whole)
    return [], "%s does not exist" % package_id


def resolve_dependencies(specification):
    """Fills `deps` of every package from its Dep cell.

    `all` is read as every package of M0…M8. Read as "every other package" it would make the
    hardening packages that say `all` depend on one another.
    """
    known = specification.by_id
    for package in specification.packages:
        resolved, notes = [], []
        raw = package.deps_raw.strip()
        if raw in ("", "—", "-"):
            package.deps, package.dep_notes = [], []
            continue
        for token in [t.strip() for t in raw.split(",") if t.strip()]:
            bare = token[3:] if token.startswith("WP-") else token
            if bare == "all":
                resolved.extend(p.id for p in specification.packages if p.milestone in ALL_MEANS)
                continue
            range_match = re.match(r"^(\d{3})([a-z]?)[–…-](?:WP-)?(\d{3})([a-z]?)$", bare)
            single_match = re.match(r"^(\d{3})([a-z]?)$", bare)
            if range_match:
                first = make_id(range_match.group(1), range_match.group(2))
                last = make_id(range_match.group(3), range_match.group(4))
                missing = [end for end in (first, last) if end not in known]
                for end in missing:
                    notes.append("range %s: end point %s does not exist" % (token, end))
                if not missing:
                    if key_of(first) > key_of(last):
                        notes.append("range %s runs backwards" % token)
                    else:
                        resolved.extend(specification.between(first, last))
            elif single_match:
                identifiers, note = resolve_reference(specification, single_match.group(1), single_match.group(2))
                if note:
                    notes.append("dependency %s: %s" % (token, note))
                resolved.extend(identifiers)
            else:
                notes.append("dependency '%s' is not an identifier, a range, 'all' or '—'" % token)
        seen, ordered = set(), []
        for identifier in resolved:
            if identifier not in seen and identifier != package.id:
                seen.add(identifier)
                ordered.append(identifier)
        if package.id in resolved and raw != "all" and "all" not in raw:
            notes.append("depends on itself")
        package.deps, package.dep_notes = ordered, notes


def references_in(text):
    """Yields (written form, first number, first suffix, last number or None, last suffix) per reference."""
    for match in REFERENCE.finditer(text):
        number, suffix, last_number, last_suffix = match.group(1), match.group(2), match.group(3), match.group(4)
        is_range = "…" in match.group(0) and (last_number or last_suffix)
        yield match.group(0), number, suffix, (last_number if is_range else None), (last_suffix if is_range else "")
