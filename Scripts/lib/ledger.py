"""Derives and checks the delivery ledger, Docs/Process/ledger.md (WP-008, §11.9).

    ledger.py --update  [--spec FILE] [--ledger FILE]   write the ledger, keeping what was filled in
    ledger.py --check   [--spec FILE] [--ledger FILE]   compare the ledger with §12 and with §11
    ledger.py --release [--spec FILE] [--ledger FILE]   list every row that keeps a release from
                                                        being made (the release checklist, WP-906)

The columns that come from §12 (package, dependencies, lenses, tag) are always re-derived. The
status is re-derived only while it is one of the three states this script computes: `Ready`,
`Blocked-on-deps`, `Awaiting-trigger`. Every other column, and every other status, belongs to
the integrator and is kept as found.

--release reads the statuses as the ledger records them (--check says whether they are current).
A release needs every package `Done`; a package retired into parts that are rows of their own
(§11.7) and an `OPT` package that awaits its trigger (WP-R5) hold nothing up. Every other row is
printed as `ledger: WP-nnn <status>`, then a tally.

Exit status: 0 consistent (for --release: every package Done), 1 findings, 2 usage error.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_packages as sp  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

COLUMNS = ["ID", "Package", "Deps", "Lenses", "Tag", "Status", "Implementer", "Verifier A", "Verifier B",
           "Time (min)", "Revision", "Report A", "Report B", "Fix cycles", "Currency check", "Stability note", "Backlog"]
DERIVED_COLUMNS = ("Package", "Deps", "Lenses", "Tag")
DERIVED_STATES = ("Ready", "Blocked-on-deps", "Awaiting-trigger")
LIFE_CYCLE = ("Implementing", "Verifying", "Fixing", "Done", "Paused", "Escalated", "Retired")
NOT_APPLICABLE = "n/a"

PREAMBLE = """# Ledger

One row per work package of §12 (§11.9). The integrator keeps it; `Scripts/ledger.sh --update`
re-derives the columns that come from the specification and leaves the rest as found, and
`Scripts/ledger.sh --check` compares it with §12 and with the definition of done (§11.8).

**Status.** `Ready`, `Blocked-on-deps` and `Awaiting-trigger` are computed: a package is ready
when every dependency is `Done` (WP-R4); a dependency on a `Retired` package means all of its
parts; an `OPT` package waits for its trigger (WP-R5) and holds nobody up while it waits. The
life cycle of §11.3 is entered by hand: `Implementing`, `Verifying`, `Fixing`, `Done`, and the
side states `Paused` (a change request is open, FIX-4), `Escalated` (three fix cycles without
convergence, FIX-3) and `Retired` (replaced by its parts, §11.7).

**A row is complete** (§11.8, item 6) when it carries: the time spent, the revision, both
reports, the number of fix cycles, the backlog items (or `none`), and, for an `ALG` package, the
dated currency check and the stability note. The three role columns record who held each role,
because no actor holds two roles on the same package (§11.1). `n/a` marks a cell that does not
apply. A part created by a split (§11.7) gets a row of its own directly under the package it
replaces. Field by field: `Docs/Process/templates/ledger-row.md`.
"""


def escape(cell):
    return cell.replace("|", "\\|")


def read_ledger(path):
    """Returns {id: {column: value}} and the order of identifiers, from an existing ledger."""
    rows, order = {}, []
    if not os.path.isfile(path):
        return rows, order
    header = None
    with open(path, encoding="utf-8") as handle:
        for line in handle.read().split("\n"):
            if not line.startswith("|"):
                header = None
                continue
            cells = sp.split_row(line)
            if cells and cells[0] == "ID":
                header = cells
                continue
            if header is None or re.match(r"^\|\s*-+", line):
                continue
            if len(cells) != len(header):
                continue
            row = dict(zip(header, cells))
            rows[row["ID"]] = row
            order.append(row["ID"])
    return rows, order


def base_of(package_id):
    match = re.match(r"^(WP-\d{3})[a-z]?$", package_id)
    return match.group(1) if match else None


def parts_in_ledger(identifier, ledger_ids):
    """Rows that are parts of `identifier` created by a split and absent from the specification."""
    if not sp.SINGLE_ID.match(identifier) or sp.key_of(identifier)[1] != "":
        return []
    return sorted((i for i in ledger_ids if base_of(i) == identifier and i != identifier), key=sp.key_of)


def build(specification, existing, existing_order):
    """Returns the rows of the new ledger, in order: [(milestone, title, [row, …]), …]."""
    by_id = specification.by_id
    spec_ids = set(by_id)
    extra = [i for i in existing_order if i not in spec_ids]

    rows = {}
    for package in specification.packages:
        old = existing.get(package.id, {})
        row = {column: old.get(column, "") for column in COLUMNS}
        row["ID"] = package.id
        row["Package"] = package.title
        row["Deps"] = package.deps_raw if package.deps_raw.strip() else "—"
        row["Lenses"] = package.lenses_raw
        row["Tag"] = package.tag
        if package.tag != "ALG":
            for column in ("Currency check", "Stability note"):
                if not row[column]:
                    row[column] = NOT_APPLICABLE
        rows[package.id] = row
    for identifier in extra:
        rows[identifier] = {column: existing[identifier].get(column, "") for column in COLUMNS}

    def done(identifier, trail=()):
        row = rows.get(identifier)
        if row is None or identifier in trail:
            return False
        status = row["Status"]
        if status == "Done":
            return True
        if status == "Retired":
            parts = [i for i in rows if base_of(i) == base_of(identifier) and i != identifier and i not in spec_ids]
            return bool(parts) and all(done(part, trail + (identifier,)) for part in parts)
        # An optional package that has not been triggered holds nobody up (WP-R5).
        return row["Tag"] == "OPT" and status in ("", "Awaiting-trigger")

    for package in specification.packages:
        row = rows[package.id]
        if row["Status"] not in ("",) + DERIVED_STATES:
            continue
        if package.tag == "OPT":
            row["Status"] = "Awaiting-trigger"
        elif all(done(dependency) for dependency in package.deps):
            row["Status"] = "Ready"
        else:
            row["Status"] = "Blocked-on-deps"

    milestones, current = [], None
    for package in specification.packages:
        if current is None or current[0] != package.milestone:
            current = (package.milestone, package.milestone_title, [])
            milestones.append(current)
        current[2].append(rows[package.id])
        for part in parts_in_ledger(package.id, extra) if sp.key_of(package.id)[1] == "" else []:
            current[2].append(rows[part])
    placed = {row["ID"] for _, _, group in milestones for row in group}
    orphans = [rows[i] for i in extra if i not in placed]
    return milestones, orphans


def render(milestones, orphans):
    out = [PREAMBLE]
    for milestone, title, group in milestones:
        out.append("## %s — %s\n" % (milestone, title))
        out.append("| " + " | ".join(COLUMNS) + " |")
        out.append("|" + "---|" * len(COLUMNS))
        for row in group:
            out.append("| " + " | ".join(escape(row[column]) for column in COLUMNS) + " |")
        out.append("")
    if orphans:
        out.append("## Rows that match no package of §12\n")
        out.append("| " + " | ".join(COLUMNS) + " |")
        out.append("|" + "---|" * len(COLUMNS))
        for row in orphans:
            out.append("| " + " | ".join(escape(row[column]) for column in COLUMNS) + " |")
        out.append("")
    return "\n".join(out)


def check(specification, existing, existing_order, ledger_path):
    findings = []
    spec_ids = [package.id for package in specification.packages]
    by_id = specification.by_id

    counts = {}
    for identifier in existing_order:
        counts[identifier] = counts.get(identifier, 0) + 1
    for identifier, count in sorted(counts.items()):
        if count > 1:
            findings.append("%s has %d rows" % (identifier, count))
    for identifier in spec_ids:
        if identifier not in existing:
            findings.append("%s has no row" % identifier)
    for identifier in existing_order:
        if identifier in by_id:
            continue
        base = base_of(identifier)
        if base in existing and existing[base].get("Status") == "Retired" and identifier != base:
            continue
        findings.append("%s is neither a package of §12 nor a part of a retired one" % identifier)

    milestones, _ = build(specification, existing, existing_order)
    derived = {row["ID"]: row for _, _, group in milestones for row in group}
    reports = os.path.join(os.path.dirname(ledger_path), "reports")
    for identifier in existing_order:
        row, expected = existing[identifier], derived.get(identifier)
        if expected is None:
            continue
        missing_columns = [column for column in COLUMNS if column not in row]
        if missing_columns:
            findings.append("%s: the row lacks the column(s) %s" % (identifier, ", ".join(missing_columns)))
            continue
        if identifier in by_id:
            for column in DERIVED_COLUMNS:
                if row[column] != expected[column]:
                    findings.append("%s: %s is '%s', §12 says '%s'" % (identifier, column, row[column], expected[column]))
        status = row["Status"]
        if status not in DERIVED_STATES + LIFE_CYCLE:
            findings.append("%s: status '%s' is not a state of §11.3" % (identifier, status))
        elif status in DERIVED_STATES and status != expected["Status"]:
            findings.append("%s: status is '%s', the dependencies say '%s' (run Scripts/ledger.sh --update)" % (identifier, status, expected["Status"]))

        people = [row[column] for column in ("Implementer", "Verifier A", "Verifier B") if row[column]]
        if len(set(people)) != len(people):
            findings.append("%s: one actor holds two roles (§11.1)" % identifier)

        if status == "Done":
            for column in ("Implementer", "Verifier A", "Verifier B", "Time (min)", "Revision", "Report A", "Report B", "Fix cycles", "Backlog"):
                if not row[column]:
                    findings.append("%s is Done but '%s' is empty (§11.8, item 6)" % (identifier, column))
            if row["Tag"] == "ALG":
                for column in ("Currency check", "Stability note"):
                    if not row[column] or row[column] == NOT_APPLICABLE:
                        findings.append("%s is Done and ALG but '%s' is empty (WP-R5)" % (identifier, column))
            if row["Fix cycles"] and not re.match(r"^[0-3]$", row["Fix cycles"]):
                findings.append("%s: fix cycles '%s' is not 0…3 (FIX-3 allows no fourth cycle)" % (identifier, row["Fix cycles"]))
            for letter in ("A", "B"):
                expected_name = "%s-%s.md" % (identifier, letter)
                if row["Report " + letter] and not os.path.isfile(os.path.join(reports, expected_name)):
                    findings.append("%s is Done but Docs/Process/reports/%s does not exist" % (identifier, expected_name))
    return findings


def release(existing, existing_order):
    """Prints the rows that keep a release from being made; returns the exit status."""
    waiting, retired, awaiting = [], 0, 0
    for identifier in existing_order:
        row = existing[identifier]
        status = row["Status"]
        if status == "Done":
            continue
        if status == "Retired" and parts_in_ledger(identifier, existing_order):
            retired += 1
            continue
        if status == "Awaiting-trigger" and row["Tag"] == "OPT":
            awaiting += 1
            continue
        waiting.append((identifier, status or "without a status"))
    held = []
    if awaiting:
        held.append("%d OPT package%s awaiting %s trigger" % (awaiting, "" if awaiting == 1 else "s", "its" if awaiting == 1 else "their"))
    if retired:
        held.append("%d retired package%s" % (retired, "" if retired == 1 else "s"))
    aside = ""
    if held:
        aside = "%s hold%s nothing up" % (" and ".join(held), "s" if awaiting + retired == 1 else "")
    for identifier, status in waiting:
        print("ledger: %s %s" % (identifier, status))
    if waiting:
        states = {}
        for _, status in waiting:
            states[status] = states.get(status, 0) + 1
        print("ledger: %d of %d rows are not Done: %s%s" % (
            len(waiting), len(existing_order), ", ".join("%d %s" % (count, state) for state, count in sorted(states.items())),
            " (%s)" % aside if aside else ""))
        return 1
    print("ledger: every package is Done (%d rows%s)" % (len(existing_order), "; " + aside if aside else ""))
    return 0


def main(arguments):
    spec_path = os.path.join(ROOT, "Docs", "Specification", "ZTronDSP-SPEC.md")
    ledger_path = os.path.join(ROOT, "Docs", "Process", "ledger.md")
    mode = None
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("--update", "--check", "--release"):
            mode = argument
        elif argument in ("--spec", "--ledger") and index + 1 < len(arguments):
            index += 1
            if argument == "--spec":
                spec_path = arguments[index]
            else:
                ledger_path = arguments[index]
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        else:
            print("ledger: unknown argument %s" % argument, file=sys.stderr)
            return 2
        index += 1
    if mode is None:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    if not os.path.isfile(spec_path):
        print("ledger: no specification at %s" % spec_path, file=sys.stderr)
        return 2

    specification = sp.read(spec_path)
    if specification.parse_findings:
        for line, message in specification.parse_findings:
            print("ledger: specification line %d: %s" % (line, message), file=sys.stderr)
        return 1
    existing, order = read_ledger(ledger_path)

    if mode == "--update":
        milestones, orphans = build(specification, existing, order)
        text = render(milestones, orphans)
        os.makedirs(os.path.dirname(ledger_path), exist_ok=True)
        with open(ledger_path, "w", encoding="utf-8") as handle:
            handle.write(text)
        total = sum(len(group) for _, _, group in milestones)
        states = {}
        for _, _, group in milestones:
            for row in group:
                states[row["Status"]] = states.get(row["Status"], 0) + 1
        print("ledger: %d rows written to %s" % (total, os.path.relpath(ledger_path, ROOT) if ledger_path.startswith(ROOT) else ledger_path))
        print("ledger: " + ", ".join("%d %s" % (count, state) for state, count in sorted(states.items())))
        for row in orphans:
            print("ledger: %s matches no package of §12 and was kept under its own heading" % row["ID"], file=sys.stderr)
        return 1 if orphans else 0

    if not os.path.isfile(ledger_path):
        print("ledger: no ledger at %s" % ledger_path, file=sys.stderr)
        return 1
    if mode == "--release":
        return release(existing, order)
    findings = check(specification, existing, order, ledger_path)
    for finding in findings:
        print("ledger: " + finding)
    if not findings:
        print("ledger: %d rows, consistent with §12 and §11" % len(order))
    return 1 if findings else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
