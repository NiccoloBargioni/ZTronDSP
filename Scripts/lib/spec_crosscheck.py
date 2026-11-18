"""The mechanical cross-check of the specification's identifiers, dependencies and references.

§13.1 names it as the check Draft 3 skipped. It reads the specification and reports; it never
edits it. Exit status: 0 when no defect was found, 1 otherwise, 2 for a usage error.

    python3 spec_crosscheck.py [path/to/ZTronDSP-SPEC.md]
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_packages as sp  # noqa: E402


def section_bounds(lines, prefix):
    """(first, last) 1-based line numbers of the '## <prefix>' section, or None."""
    start = None
    for number, line in enumerate(lines, start=1):
        if line.startswith("## "):
            if start is not None:
                return start, number - 1
            if line.startswith("## " + prefix):
                start = number
    return (start, len(lines)) if start is not None else None


def strongly_connected(graph):
    """Tarjan's algorithm, iterative. Returns the components that hold a cycle."""
    index_of, low, on_stack, stack, components, counter = {}, {}, set(), [], [], [0]
    for root in graph:
        if root in index_of:
            continue
        work = [(root, iter(graph.get(root, ())))]
        index_of[root] = low[root] = counter[0]
        counter[0] += 1
        stack.append(root)
        on_stack.add(root)
        while work:
            node, successors = work[-1]
            advanced = False
            for successor in successors:
                if successor not in graph:
                    continue
                if successor not in index_of:
                    index_of[successor] = low[successor] = counter[0]
                    counter[0] += 1
                    stack.append(successor)
                    on_stack.add(successor)
                    work.append((successor, iter(graph.get(successor, ()))))
                    advanced = True
                    break
                if successor in on_stack:
                    low[node] = min(low[node], index_of[successor])
            if advanced:
                continue
            work.pop()
            if work:
                parent = work[-1][0]
                low[parent] = min(low[parent], low[node])
            if low[node] == index_of[node]:
                component = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1 or node in graph.get(node, ()):
                    components.append(sorted(component, key=sp.key_of))
    return components


def check_reference(specification, written, number, suffix, last_number, last_suffix):
    """Returns (defects, notes) for one reference found in running text."""
    defects, notes = [], []
    identifiers, note = sp.resolve_reference(specification, number, suffix)
    if note and not identifiers:
        defects.append("%s: %s" % (written, note))
    elif note:
        notes.append("%s: %s" % (written, note))
    if last_number is not None or last_suffix:
        end_number = last_number if last_number is not None else number
        end_identifiers, end_note = sp.resolve_reference(specification, end_number, last_suffix)
        if end_note and not end_identifiers:
            defects.append("%s: range end %s" % (written, end_note))
        elif end_note:
            notes.append("%s: range end %s" % (written, end_note))
        if identifiers and end_identifiers and sp.key_of(identifiers[0]) > sp.key_of(end_identifiers[-1]):
            defects.append("%s: the range runs backwards" % written)
    return defects, notes


def run(path):
    specification = sp.read(path)
    lines = specification.lines
    defects, notes = [], []   # (class, text)

    def defect(kind, text):
        defects.append((kind, text))

    def note(kind, text):
        notes.append((kind, text))

    # --- Parsing ---------------------------------------------------------------------------
    for line, message in specification.parse_findings:
        defect("parse", "line %d: %s" % (line, message))

    # --- Counts ----------------------------------------------------------------------------
    claimed = None
    for line in lines:
        match = re.search(r"there are (\d+), in (\d+) rows", line)
        if match:
            claimed = (int(match.group(1)), int(match.group(2)))
            break
    package_count, row_count = len(specification.packages), specification.rows
    if claimed is None:
        defect("counts", "the specification states no package count to compare with (%d packages in %d rows were read)" % (package_count, row_count))
    elif claimed != (package_count, row_count):
        defect("counts", "the specification claims %d packages in %d rows; §12 holds %d packages in %d rows" % (claimed[0], claimed[1], package_count, row_count))

    # --- Duplicate identifiers ---------------------------------------------------------------
    seen = {}
    for package in specification.packages:
        if package.id in seen:
            defect("duplicate", "%s is defined on line %d and again on line %d" % (package.id, seen[package.id], package.line))
        else:
            seen[package.id] = package.line

    # --- Dependencies ------------------------------------------------------------------------
    for package in specification.packages:
        for text in package.dep_notes:
            if "exists only as its parts" in text:
                note("split dependency", "%s (line %d): %s; WP-R4 reads it as all of the parts" % (package.id, package.line, text))
            else:
                defect("dangling dependency", "%s (line %d): %s" % (package.id, package.line, text))

    graph = {package.id: list(package.deps) for package in specification.packages}
    for component in strongly_connected(graph):
        defect("cycle", "dependency cycle: " + " → ".join(component + [component[0]]))

    said_all = [package.id for package in specification.packages if "all" in [t.strip() for t in package.deps_raw.split(",")]]
    if said_all:
        note("reading of 'all'", "'all' (%s) is read as every package of M0…M8; read as every other package it would make those packages depend on one another" % ", ".join(said_all))

    # An OPT package runs only on its trigger (WP-R5), so nothing mandatory may wait for one.
    # (`all` is not counted: it names every package, the optional ones among them.)
    by_identifier = specification.by_id
    for package in specification.packages:
        if package.tag == "OPT":
            continue
        named = set()
        for token in [t.strip() for t in package.deps_raw.split(",") if t.strip() and t.strip() != "all"]:
            bare = token[3:] if token.startswith("WP-") else token
            match = re.match(r"^(\d{3})([a-z]?)(?:[–…-](?:WP-)?(\d{3})([a-z]?))?$", bare)
            if not match:
                continue
            first = sp.make_id(match.group(1), match.group(2))
            if match.group(3):
                last = sp.make_id(match.group(3), match.group(4))
                if first in by_identifier and last in by_identifier:
                    named.update(specification.between(first, last))
            elif first in by_identifier:
                named.add(first)
        for dependency in sorted(named, key=sp.key_of):
            if by_identifier[dependency].tag == "OPT":
                defect("optional dependency", "%s (line %d) depends on %s, which is OPT and runs only on its trigger (WP-R5)" % (package.id, package.line, dependency))

    # --- Lenses and tags ---------------------------------------------------------------------
    for package in specification.packages:
        letters = [part.strip() for part in package.lenses_raw.split(",")]
        if len(letters) != 2 or any(len(l) != 1 or l not in sp.LENSES for l in letters) or letters[0] == letters[1]:
            defect("lenses", "%s (line %d): lenses '%s' are not two distinct letters of N R A T V S" % (package.id, package.line, package.lenses_raw))
        if package.tag not in ("", "ALG", "OPT"):
            defect("tag", "%s (line %d): tag '%s' is neither ALG nor OPT" % (package.id, package.line, package.tag))

    # --- §2: requirement rows ----------------------------------------------------------------
    bounds_2 = section_bounds(lines, "2.")
    requirement_numbers = []
    if bounds_2 is None:
        defect("traceability", "section 2 was not found")
    else:
        for number in range(bounds_2[0], bounds_2[1] + 1):
            line = lines[number - 1]
            if not re.match(r"^\|\s*R-\d+", line):
                continue
            cells = sp.split_row(line)
            requirement = cells[0]
            requirement_numbers.append(int(requirement.split("-")[1]))
            if len(cells) != 4:
                defect("traceability", "%s (line %d): row has %d cells, expected 4" % (requirement, number, len(cells)))
                continue
            for written, first, suffix, last, last_suffix in sp.references_in(cells[3]):
                found, remarks = check_reference(specification, written, first, suffix, last, last_suffix)
                for text in found:
                    defect("traceability", "%s (line %d) names %s" % (requirement, number, text))
                for text in remarks:
                    note("traceability", "%s (line %d) names %s" % (requirement, number, text))
        expected = list(range(1, len(requirement_numbers) + 1))
        if requirement_numbers != expected:
            defect("traceability", "requirement numbers are not R-01…R-%02d in order: %s" % (len(requirement_numbers), requirement_numbers))

    # --- §12: the milestone table against the milestone sections ---------------------------------
    first_last = {}
    for package in specification.packages:
        entry = first_last.setdefault(package.milestone, [package.id, package.id])
        if sp.key_of(package.id) < sp.key_of(entry[0]):
            entry[0] = package.id
        if sp.key_of(package.id) > sp.key_of(entry[1]):
            entry[1] = package.id
    bounds_12 = section_bounds(lines, "12.")
    if bounds_12:
        for number in range(bounds_12[0], bounds_12[1] + 1):
            match = re.match(r"^\|\s*(M\d) [^|]*\|\s*(WP-[^|]+?)\s*\|", lines[number - 1])
            if not match:
                continue
            milestone, written = match.group(1), match.group(2)
            reference = list(sp.references_in(written))
            if len(reference) != 1 or milestone not in first_last:
                defect("milestone table", "line %d: cannot read the package range '%s' of %s" % (number, written, milestone))
                continue
            _, first, suffix, last, last_suffix = reference[0]
            stated = (sp.make_id(first, suffix), sp.make_id(last if last is not None else first, last_suffix))
            actual = tuple(first_last[milestone])
            if stated != actual:
                defect("milestone table", "line %d: %s is given as %s, its section runs from %s to %s" % (number, milestone, written, actual[0], actual[1]))

    # --- Every other reference in the document ---------------------------------------------------
    inside_2 = set(range(bounds_2[0], bounds_2[1] + 1)) if bounds_2 else set()
    package_lines = {package.line for package in specification.packages}
    for number, line in enumerate(lines, start=1):
        if number in inside_2:
            continue
        text = line
        if number in package_lines:
            cells = sp.split_row(line)
            text = " | ".join(cells[1:2] + cells[3:])   # the ID and Dep cells are checked above
        for written, first, suffix, last, last_suffix in sp.references_in(text):
            found, remarks = check_reference(specification, written, first, suffix, last, last_suffix)
            for item in found:
                defect("reference", "line %d names %s" % (number, item))
            for item in remarks:
                note("reference", "line %d names %s" % (number, item))

    # --- OPT triggers ----------------------------------------------------------------------------
    tagged = sorted((package.id for package in specification.packages if package.tag == "OPT"), key=sp.key_of)
    triggers = []
    for line in lines:
        if line.startswith("`OPT` triggers."):
            triggers = sorted({sp.make_id(n, s) for _, n, s, _, _ in sp.references_in(line)}, key=sp.key_of)
    if triggers != tagged:
        defect("OPT triggers", "packages tagged OPT are %s; triggers are listed for %s" % (", ".join(tagged) or "none", ", ".join(triggers) or "none"))

    # --- Dependencies on a later milestone, against the list §12 gives ---------------------------------
    # §12 lists "the places where a package waits for a later milestone". Every dependency that
    # points to a higher-numbered milestone has to belong to a package named in that list.
    by_id = specification.by_id
    announced = set()
    for line in lines:
        if not re.match(r"^- In M\d, ", line):
            continue
        for written, first, suffix, last, last_suffix in sp.references_in(line):
            start = sp.make_id(first, suffix)
            if last is not None or last_suffix:
                end = sp.make_id(last if last is not None else first, last_suffix)
                if start in by_id and end in by_id:
                    announced.update(specification.between(start, end))
            elif start in by_id:
                announced.add(start)
    for package in specification.packages:
        if package.milestone not in sp.ALL_MEANS:
            continue
        later = [d for d in package.deps if by_id[d].milestone > package.milestone]
        if later and package.id not in announced:
            defect("unannounced wait", "%s (%s, line %d) depends on %s in a later milestone, and §12's list of such places does not name it" % (
                package.id, package.milestone, package.line, ", ".join(later)))

    return specification, defects, notes


def main(arguments):
    if len(arguments) > 1 or (arguments and arguments[0] in ("-h", "--help")):
        print(__doc__.strip())
        return 2 if len(arguments) > 1 else 0
    default = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Docs", "Specification", "ZTronDSP-SPEC.md")
    path = arguments[0] if arguments else default
    if not os.path.isfile(path):
        print("spec-crosscheck: no specification at %s" % path, file=sys.stderr)
        return 2
    specification, defects, notes = run(path)

    print("Specification: %s" % os.path.normpath(path))
    print("Read %d packages in %d rows, %d of them ALG, %d OPT." % (
        len(specification.packages), specification.rows,
        sum(1 for p in specification.packages if p.tag == "ALG"),
        sum(1 for p in specification.packages if p.tag == "OPT")))
    print()
    if defects:
        print("DEFECTS (%d)" % len(defects))
        for kind, text in defects:
            print("  [%s] %s" % (kind, text))
    else:
        print("DEFECTS (0)")
    print()
    print("NOTES (%d) — readings the check had to choose, not defects" % len(notes))
    for kind, text in notes:
        print("  [%s] %s" % (kind, text))
    return 1 if defects else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
