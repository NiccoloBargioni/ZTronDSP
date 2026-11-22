"""Checks the audit of the algorithm and stability registers (WP-905, §7.2, §7.3, §7.5) mechanically.

    registers.py [--root DIR] [--spec FILE] [--audit FILE] [--numerics DIR]

Defaults: the package that holds this script, its specification, Docs/Numerics and the newest
`Docs/Numerics/register-audit-*.md`. Exit status: 0 the table holds, 1 a check failed, 2 usage
error or a file that cannot be read.

The audit is a markdown table, one row per row of the algorithm register §7.2, with the columns

    | # | Operation | Packages | Notes | Currency | Notes against the code | Stress tests | Mutations | Precision | Open |

What is checked:
  * the table has one row per row of §7.2, numbered as §7.2 numbers them, in order, and the
    operation of each row is the operation §7.2 gives it; the stability register §7.5 has a row of
    the same number for each (NUMS-1);
  * no cell is empty (an honest "none", "open: <finding>" or "not searched on <date>" is a filled
    cell; "", "-", "—", "pending", "TBD" and "TODO" are not);
  * the Currency cell of every row carries a date, YYYY-MM-DD, that exists;
  * every file a row names in backticks (a path with a slash and an extension) exists, and every
    note of the Notes column exists in the notes folder;
  * every test of the Stress tests column is named with its file, as groups
    "`Tests/…/File.swift`: `test`, `Suite.test`" separated by ";", and each one is declared in
    that file (`func test(`; for `Suite.test` the file also declares the suite);
  * every package of the Packages column is tagged ALG in §12, and every ALG package of §12 is in
    exactly one row (the tag column is read with spec_packages.py);
  * every row names at least one note, and every note of the notes folder is named by a row or
    listed after "**Supplementary notes.**" under the table (the currency records
    `currency-*.md` and the audits `register-audit-*.md` themselves are not notes).
"""

import datetime
import glob
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import spec_packages  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
COLUMNS = ["#", "Operation", "Packages", "Notes", "Currency", "Notes against the code", "Stress tests",
           "Mutations", "Precision", "Open"]
EMPTY = {"", "-", "—", "–", "pending", "tbd", "todo", "…", "..."}
PATH = re.compile(r"`([^`\s]+/[^`\s]+\.(?:swift|c|h|m|metal|md|py|sh|json|txt|tsv))`")
TICKED = re.compile(r"`([^`]+)`")
DATE = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
PACKAGE = re.compile(r"\bWP-\d{3}[a-z]?\b")
SUPPLEMENTARY = "**Supplementary notes.**"


def register_rows(lines, heading):
    """The rows of the first table under a `### 7.x` heading: {number: cells}."""
    rows, inside = {}, False
    for line in lines:
        if line.startswith("### "):
            inside = line.startswith(heading)
            continue
        if line.startswith("## ") or line.strip() == "---":
            inside = False
        if not inside or not line.startswith("|"):
            continue
        cells = spec_packages.split_row(line)
        if cells and re.fullmatch(r"\d+", cells[0]):
            rows[int(cells[0])] = cells
    return rows


def audit_table(lines):
    """(header, rows, supplementary notes, problems) of the audit file."""
    header, rows, problems, supplementary = None, [], [], []
    for number, line in enumerate(lines, start=1):
        if header is None:
            if line.startswith("| #"):
                header = spec_packages.split_row(line)
            continue
        if not line.startswith("|"):
            if rows:
                break
            continue
        if re.match(r"^\|\s*-+\s*\|", line):
            continue
        rows.append((number, spec_packages.split_row(line)))
    for line in lines:
        if line.startswith(SUPPLEMENTARY):
            supplementary.extend(name for name in TICKED.findall(line) if name.endswith(".md"))
    return header, rows, supplementary, problems


def declared(path, name):
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return False
    suite, _, function = name.rpartition(".")
    if not re.search(r"\bfunc\s+%s\s*[(<]" % re.escape(function), text):
        return False
    if suite and not re.search(r"\b(?:struct|class|final class|enum|extension)\s+%s\b" % re.escape(suite), text):
        return False
    return True


def check(root, spec_path, audit_path, numerics):
    problems = []

    def problem(text):
        problems.append(text)

    try:
        spec_lines = open(spec_path, encoding="utf-8").read().split("\n")
        audit_lines = open(audit_path, encoding="utf-8").read().split("\n")
    except OSError as error:
        print("registers: cannot read %s" % error, file=sys.stderr)
        return 2

    algorithm = register_rows(spec_lines, "### 7.2")
    stability = register_rows(spec_lines, "### 7.5")
    if not algorithm:
        problem("the specification has no algorithm register (§7.2)")
    specification = spec_packages.read(spec_path)
    alg_packages = [p.id for p in specification.packages if "ALG" in p.tag.split()]

    header, rows, supplementary, _ = audit_table(audit_lines)
    audit_name = os.path.relpath(audit_path, root)
    if header is None:
        problem("%s: no table whose header begins with '| #'" % audit_name)
        header = []
    if header and header != COLUMNS:
        problem("%s: the header is %s, expected %s" % (audit_name, " | ".join(header), " | ".join(COLUMNS)))
    if len(rows) != len(algorithm):
        problem("%s: %d rows, expected %d (one per row of §7.2)" % (audit_name, len(rows), len(algorithm)))

    seen_packages, named_notes, tests_checked, files_checked = {}, set(), 0, 0
    for position, (line_number, cells) in enumerate(rows, start=1):
        where = "%s:%d" % (audit_name, line_number)
        if len(cells) != len(COLUMNS):
            problem("%s: %d cells, expected %d" % (where, len(cells), len(COLUMNS)))
            continue
        row = dict(zip(COLUMNS, cells))
        for column in COLUMNS:
            if row[column].strip().lower() in EMPTY:
                problem("%s: row %s, the cell '%s' is empty" % (where, row["#"], column))
        if row["#"] != str(position):
            problem("%s: row number %s, expected %d" % (where, row["#"], position))
        register = algorithm.get(position)
        if register and register[1] != row["Operation"]:
            problem("%s: row %d is '%s' in §7.2, not '%s'" % (where, position, register[1], row["Operation"]))
        if position not in stability:
            problem("%s: row %d has no twin in the stability register §7.5 (NUMS-1)" % (where, position))
        dates = DATE.findall(row["Currency"])
        valid = []
        for year, month, day in dates:
            try:
                valid.append(datetime.date(int(year), int(month), int(day)))
            except ValueError:
                problem("%s: row %d, the currency date %s-%s-%s does not exist" % (where, position, year, month, day))
        if not dates:
            problem("%s: row %d, the currency check carries no date (YYYY-MM-DD)" % (where, position))
        for column in COLUMNS:
            for path in PATH.findall(row[column]):
                files_checked += 1
                if not os.path.exists(os.path.join(root, path)):
                    problem("%s: row %d names %s, which does not exist" % (where, position, path))
        notes = [name for name in TICKED.findall(row["Notes"]) if name.endswith(".md")]
        if not notes:
            problem("%s: row %d names no stability note (NUMS-1)" % (where, position))
        for note in notes:
            named_notes.add(os.path.basename(note))
            if not os.path.exists(os.path.join(numerics, os.path.basename(note))):
                problem("%s: row %d names the note %s, which is not in %s" % (where, position, note, os.path.relpath(numerics, root)))
        for package in PACKAGE.findall(row["Packages"]):
            if package not in alg_packages:
                problem("%s: row %d lists %s, which §12 does not tag ALG" % (where, position, package))
            seen_packages.setdefault(package, []).append(position)
        for group in [g.strip() for g in row["Stress tests"].split(";") if g.strip()]:
            ticked = TICKED.findall(group)
            files = [t for t in ticked if t.endswith(".swift")]
            names = [t for t in ticked if not t.endswith(".swift")]
            if len(files) != 1:
                problem("%s: row %d, the tests '%s' are not named with one file" % (where, position, group[:80]))
                continue
            if not names:
                problem("%s: row %d names the file %s without a test" % (where, position, files[0]))
            for name in names:
                tests_checked += 1
                if not declared(os.path.join(root, files[0]), name):
                    problem("%s: row %d names the test %s, which %s does not declare" % (where, position, name, files[0]))

    for package in alg_packages:
        places = seen_packages.get(package, [])
        if len(places) == 0:
            problem("%s: the ALG package %s is in no row" % (audit_name, package))
        elif len(places) > 1:
            problem("%s: the ALG package %s is in rows %s; it belongs in exactly one" % (audit_name, package, ", ".join(map(str, places))))
    excluded = ("currency-", "register-audit-")
    for path in sorted(glob.glob(os.path.join(numerics, "*.md"))):
        name = os.path.basename(path)
        if name.startswith(excluded):
            continue
        if name not in named_notes and name not in supplementary:
            problem("%s: the note %s is named by no row and not listed as supplementary" % (audit_name, name))
    for name in supplementary:
        if not os.path.exists(os.path.join(numerics, name)):
            problem("%s: the supplementary note %s does not exist" % (audit_name, name))

    for text in problems:
        print("registers: FAIL: %s" % text)
    if problems:
        print("registers: %d problems" % len(problems))
        return 1
    print("registers: %d rows, %d ALG packages, %d notes (%d supplementary), %d tests and %d files checked: OK"
          % (len(rows), len(alg_packages), len(named_notes), len(supplementary), tests_checked, files_checked))
    return 0


def main(arguments):
    root, spec, audit, numerics = ROOT, None, None, None
    index = 0
    while index < len(arguments):
        flag = arguments[index]
        if flag in ("-h", "--help"):
            print(__doc__)
            return 0
        if flag not in ("--root", "--spec", "--audit", "--numerics") or index + 1 >= len(arguments):
            print("registers: usage: registers.py [--root DIR] [--spec FILE] [--audit FILE] [--numerics DIR]", file=sys.stderr)
            return 2
        value = arguments[index + 1]
        if flag == "--root":
            root = os.path.abspath(value)
        elif flag == "--spec":
            spec = os.path.abspath(value)
        elif flag == "--audit":
            audit = os.path.abspath(value)
        else:
            numerics = os.path.abspath(value)
        index += 2
    spec = spec or os.path.join(root, "Docs", "Specification", "ZTronDSP-SPEC.md")
    numerics = numerics or os.path.join(root, "Docs", "Numerics")
    if audit is None:
        audits = sorted(glob.glob(os.path.join(numerics, "register-audit-*.md")))
        if not audits:
            print("registers: FAIL: there is no %s/register-audit-*.md" % os.path.relpath(numerics, root))
            return 1
        audit = audits[-1]
    return check(root, spec, audit, numerics)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
