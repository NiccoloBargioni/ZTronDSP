#!/bin/bash
# The external parity suite and the examples of the extension guide (WP-907, WP-908; EXT-4;
# CI gate 9 of §10.3).
#
# ExternalParity/ is a package of its own inside the repository. It depends on this package by
# path and on its three products only, as an app does. It holds three stock stages written
# again on the public API (a gain as a SampleProcessor, a low-pass on a C kernel of its own, a
# mel projection as a step family with its node) and one example for every row of §5.11.1,
# the ones Docs/ExtensionGuide.md shows. This script holds them to what EXT-4 asks.
#
#   Scripts/external-parity.sh                every step, in order; stops at the first that fails
#   Scripts/external-parity.sh --step NAME    the named step (repeat --step for several; they run
#                                             in the order of the list below)
#   Scripts/external-parity.sh --keep-going   run the remaining steps after a failure
#   Scripts/external-parity.sh --launches N   launches the speed check may take to hold its bound
#                                             (default 3; the first that holds it counts)
#   Scripts/external-parity.sh --list         what each step runs
#
# The steps:
#   rules     No simulator. The external package depends on the three products and on nothing
#             else: its manifest names them alone, its sources import them alone, and nothing
#             in it says @testable or @_spi. The bans of Scripts/lint-bans.sh hold in it where
#             they apply: no UIKit, no Combine, no AnyView, no configuration objects, the
#             hot-path bans in its Kernels/ and Nodes/ folders, a register for every
#             `@unchecked Sendable`. SwiftUI is imported by its tests and by the one target
#             that shows a view.
#   guide     No simulator. Docs/ExtensionGuide.md has a section for every row of §5.11.1 that
#             says what to conform to, where it runs, what the author supplies, its latency and
#             settling time and its threading contract; and every Swift or C block the guide
#             shows is, character for character, a marked region of a file the external
#             package compiles.
#   build     Builds the external package for testing, in Debug, for the simulator.
#   test      Runs its tests in Debug: the three stages against their stock twins, bound
#             switches, latency, settling and updates, the allocation audits, the examples of
#             the guide.
#   fixtures  Its compile fixtures against the Debug build (Scripts/compile-fixtures.sh): what
#             must compile does, and what must not fails with a sentence that names the step
#             the user wrote (ORD-4).
#   release   Builds it for testing in Release.
#   audits    The allocation audits once more, in Release (CR-002).
#   speed     The speed check, in Release, by itself and one test at a time: every stage within
#             5 % of its stock twin on blocks of 512 frames (§5.7).
#
# An expectation that is known to fail is shown with its test, never hidden: the control case
# of the audits (a stage that allocates must be counted), and the findings about this package
# that the suite states as tests. Such a test turns into a failure once what it reports is
# fixed, so the list shrinks only on purpose.
#
# Environment:
#   ZTD_DEVICE                 the simulator, as Scripts/xc.sh takes it (created and booted if
#                              need be)
#   ZTD_EXTERNAL_DERIVED       derived data of the external package's builds (default
#                              <package>/.build/external-parity). Its own folder: the builds of
#                              Scripts/ci.sh carry coverage instrumentation, and timings taken
#                              with it would not be the product's.
#   ZTD_EXTERNAL_TREE          the external package (default <package>/ExternalParity)
#   ZTD_EXTERNAL_GUIDE         the guide (default <package>/Docs/ExtensionGuide.md)
#   ZTD_EXTERNAL_SPECIFICATION the specification, for the rows of §5.11.1
#   ZTD_EXTERNAL_SEEDED_VIOLATION
#                              handed to the tests of the `test` step: `gain` makes the stock
#                              twin of the gain's parity test another gain, so that the two
#                              outputs differ (the self-test)
#   ZTD_EXTERNAL_XC, ZTD_EXTERNAL_XCODEBUILD, ZTD_EXTERNAL_FIXTURES
#                              stand-ins for Scripts/xc.sh, xcodebuild and
#                              Scripts/compile-fixtures.sh (the self-test)
#
# The full output of each step is kept at $ZTD_EXTERNAL_DERIVED/logs/<step>.log, and the figures
# of the speed check that held at $ZTD_EXTERNAL_DERIVED/speed.json.
# Exit status: 0 every step passed, 1 a step failed, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TREE="${ZTD_EXTERNAL_TREE:-$ROOT/ExternalParity}"
GUIDE="${ZTD_EXTERNAL_GUIDE:-$ROOT/Docs/ExtensionGuide.md}"
SPECIFICATION="${ZTD_EXTERNAL_SPECIFICATION:-$ROOT/Docs/Specification/ZTronDSP-SPEC.md}"
DERIVED="${ZTD_EXTERNAL_DERIVED:-$ROOT/.build/external-parity}"
XC="${ZTD_EXTERNAL_XC:-$ROOT/Scripts/xc.sh}"
XCODEBUILD="${ZTD_EXTERNAL_XCODEBUILD:-xcodebuild}"
FIXTURES="${ZTD_EXTERNAL_FIXTURES:-$ROOT/Scripts/compile-fixtures.sh}"
SCHEME="ExternalParity-Package"
STEPS="rules guide build test fixtures release audits speed"
AUDIT_SUITES="ExternalStagesTests/AllocationAuditTests ExtensionGuideTests/GuideAllocationAuditTests"
SPEED_SUITE="ExternalStagesTests/SpeedTests"

wanted=""; keep_going=0; launches=3
while [ $# -gt 0 ]; do
    case "$1" in
        --step)
            [ $# -ge 2 ] || { echo "external-parity: --step takes a name ($STEPS)" >&2; exit 2; }
            case " $STEPS " in *" $2 "*) wanted="$wanted $2" ;; *) echo "external-parity: there is no step $2 ($STEPS)" >&2; exit 2 ;; esac
            shift ;;
        --launches)
            [ $# -ge 2 ] || { echo "external-parity: --launches takes a number" >&2; exit 2; }
            case "$2" in ''|*[!0-9]*|0) echo "external-parity: --launches takes a positive number" >&2; exit 2 ;; esac
            launches="$2"; shift ;;
        --keep-going) keep_going=1 ;;
        --list) awk '/^# The steps:/ { on = 1 } on && /^#$/ { exit } on { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 0 ;;
        -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "external-parity: unknown argument $1" >&2; exit 2 ;;
    esac
    shift
done
[ -n "$wanted" ] || wanted="$STEPS"
if [ ! -f "$TREE/Package.swift" ]; then
    echo "external-parity: there is no package at $TREE" >&2
    exit 2
fi

LOGS="$DERIVED/logs"
mkdir -p "$LOGS" "$DERIVED/tmp" || { echo "external-parity: cannot write under $DERIVED" >&2; exit 2; }

current=""
say() { printf 'external-parity: [%s] %s\n' "$current" "$*"; }
indent() { sed 's/^/    | /'; }

# ---------------------------------------------------------------------------------------------
# xcodebuild on the external package
# ---------------------------------------------------------------------------------------------
UDID=""
device() {
    [ -n "$UDID" ] && return 0
    UDID="$("$XC" device)" || UDID=""
    if [ -z "$UDID" ]; then
        say "there is no simulator to run on (Scripts/xc.sh device; ZTD_DEVICE=${ZTD_DEVICE:-})"
        return 1
    fi
}

# xcode <log> <configuration> <xcodebuild arguments …>: the whole output goes to the log. What
# XCENV holds is added to the environment; a variable named TEST_RUNNER_<NAME> reaches the tests
# as <NAME>. Coverage is off: its instrumentation distorts timings.
XCENV=()
xcode() {
    local log="$1" configuration="$2"; shift 2
    device || return 1
    ( cd "$TREE" && env ${XCENV[@]+"${XCENV[@]}"} "$XCODEBUILD" -scheme "$SCHEME" \
        -destination "platform=iOS Simulator,id=$UDID" \
        -derivedDataPath "$DERIVED" \
        -configuration "$configuration" \
        -collect-test-diagnostics never \
        -enableCodeCoverage NO \
        "$@" ) > "$log" 2>&1
}

# What a log says went wrong, in the lines xcodebuild and Swift Testing write for it.
problems() {
    grep -a -E "error:|✘|recorded an issue|Testing failed|Fatal error|Crash|crashed|Restarting after unexpected exit|Assertion failed|\*\* (TEST )?(BUILD|EXECUTE) FAILED" "$1" \
        | grep -a -v -E "IDERunDestination|DVTDeviceOperation|appintentsmetadataprocessor" | awk '!seen[$0]++' | cut -c1-700 | head -60
}

# The expectations of a log that are known to fail, one line each, with their test.
known_issues() {
    grep -a "recorded a known issue" "$1" | sed -E 's/^[^A-Za-z]*//' | awk '!seen[$0]++' | cut -c1-400
}

# verdict <log> <status of xcodebuild>: true when xcodebuild succeeded, at least one test ran
# and no run failed. Says what ran, and lists the known issues.
verdict() {
    local log="$1" status="$2" runs tests failed known
    runs="$(grep -a -E "Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)" "$log")"
    tests="$(printf '%s\n' "$runs" | sed -n -E 's/.*Test run with ([0-9]+) tests? in.*/\1/p' | awk '{ sum += $1 } END { print sum + 0 }')"
    failed="$(printf '%s\n' "$runs" | grep -c " failed ")"
    known="$(known_issues "$log" | wc -l | tr -d ' ')"
    if [ "$status" -ne 0 ] || [ "$failed" -ne 0 ]; then
        say "tests failed (xcodebuild exit $status); the log is $log"
        problems "$log" | indent
        return 1
    fi
    if [ "$tests" -eq 0 ]; then
        say "no test ran: a run that tests nothing proves nothing; the log is $log"
        problems "$log" | indent
        return 1
    fi
    say "$tests tests passed$([ "$known" -gt 0 ] && echo "; $known expectations are known to fail and did:")"
    [ "$known" -gt 0 ] && known_issues "$log" | indent
    return 0
}

built() {   # <configuration>: whether its build for testing is there
    [ -d "$DERIVED/Build/Products/$1-iphonesimulator/ExternalStages.swiftmodule" ] || [ -n "${ZTD_EXTERNAL_XCODEBUILD:-}" ]
}

# ---------------------------------------------------------------------------------------------
# rules
# ---------------------------------------------------------------------------------------------
step_rules() {
    python3 - "$ROOT" "$TREE" <<'PY'
import os, re, subprocess, sys

root, tree = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "Scripts", "lib"))
import source_scan as scan

PRODUCTS = ("ZTronDSP", "ZTronDSPUI", "ZTronDSPTesting")
ANYWHERE = {"Foundation", "Darwin", "Accelerate", "ZTronDSP"}
IN_TESTS = {"Testing", "ZTronDSPTesting", "SwiftUI", "ZTronDSPUI"}
IN_THE_VIEW_TARGET = {"SwiftUI", "ZTronDSPUI"}
VIEW_TARGET = "Sources/ExtensionGuideUI/"
SKIPPED = {".build", ".swiftpm", ".git", "DerivedData", "Docs", "__pycache__"}
C_EXTENSIONS = (".c", ".h", ".m", ".cpp", ".mm")

findings = []


def finding(path, line, rule, message):
    findings.append((path, line, rule, message))


def line_of(text, offset):
    return text.count("\n", 0, offset) + 1


def without_comments(text):
    """The text with its comments blanked; string literals and line breaks stay where they are."""
    out, index, in_string = [], 0, False
    while index < len(text):
        character = text[index]
        if in_string:
            out.append(character)
            if character == "\\" and index + 1 < len(text):
                out.append(text[index + 1])
                index += 1
            elif character == "\"":
                in_string = False
        elif character == "\"":
            in_string = True
            out.append(character)
        elif text.startswith("//", index):
            while index < len(text) and text[index] != "\n":
                index += 1
            continue
        elif text.startswith("/*", index):
            end = text.find("*/", index + 2)
            end = len(text) if end < 0 else end + 2
            out.append("".join("\n" if c == "\n" else " " for c in text[index:end]))
            index = end
            continue
        else:
            out.append(character)
        index += 1
    return "".join(out)


def call_at(code, offset):
    """The call that begins at `offset`, up to the parenthesis that closes it, on one line."""
    depth, index = 0, offset
    while index < len(code):
        if code[index] == "(":
            depth += 1
        elif code[index] == ")":
            depth -= 1
            if depth == 0:
                break
        index += 1
    return re.sub(r"\s+", " ", code[offset:index + 1]).strip()


# The manifest: one dependency, by path, and its three products.
manifest = open(os.path.join(tree, "Package.swift"), encoding="utf-8").read()
code = without_comments(manifest)
own = set(re.findall(r"\.(?:target|testTarget|executableTarget|systemLibrary|plugin|macro)\s*\(\s*name:\s*\"([^\"]+)\"", code))
PACKAGE = re.compile(r"\.package\s*\(\s*name:\s*\"ZTronDSP\"\s*,\s*path:\s*\"\.\.\"\s*\)")
PRODUCT = re.compile(r"\.product\s*\(\s*name:\s*\"(%s)\"\s*,\s*package:\s*\"ZTronDSP\"\s*\)" % "|".join(PRODUCTS))
packages = list(re.finditer(r"\.package\s*\(", code))
for match in packages:
    if not PACKAGE.match(code, match.start()):
        finding("Package.swift", line_of(code, match.start()), "EXT-4",
                "`%s`: the external package depends on ZTronDSP by path, `.package(name: \"ZTronDSP\", path: \"..\")`, and on nothing else"
                % call_at(code, match.start()))
if not packages:
    finding("Package.swift", 1, "EXT-4", "the manifest names no dependency on ZTronDSP")
for match in re.finditer(r"\.product\s*\(", code):
    if not PRODUCT.match(code, match.start()):
        finding("Package.swift", line_of(code, match.start()), "EXT-4",
                "`%s`: the external package uses the three products of ZTronDSP (%s) and nothing else" % (call_at(code, match.start()), ", ".join(PRODUCTS)))
for match in re.finditer(r"\bdependencies\s*:\s*\[", code):
    depth, index = 1, match.end()
    while index < len(code) and depth:
        depth += {"[": 1, "]": -1}.get(code[index], 0)
        index += 1
    block = re.sub(r"\.(?:package|product)\s*\([^()]*\)", "", code[match.end():index - 1])
    for name in re.finditer(r"\"([^\"]*)\"", block):
        if name.group(1) not in own:
            finding("Package.swift", line_of(code, match.end() + 0), "EXT-4",
                    "a target depends on \"%s\", which is not a target of this package: what comes from ZTronDSP is named as one of its three products" % name.group(1))
for match in re.finditer(r"\bunsafeFlags\b", code):
    finding("Package.swift", line_of(code, match.start()), "EXT-4", "`unsafeFlags`: the external package is built as any client is")

# The sources: what they import, and no hidden channel.
IMPORT = re.compile(
    r"^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|internal|private|fileprivate|package)[ \t]+)?"
    r"import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|var|let)[ \t]+)?([A-Za-z_]\w*)", re.MULTILINE)
INCLUDE = re.compile(r"^[ \t]*#[ \t]*(?:include|import)[ \t]*([<\"])([^>\"\n]+)[>\"]", re.MULTILINE)
public_headers = set()
headers_folder = os.path.join(root, "Sources", "CZTronDSP", "include")
if os.path.isdir(headers_folder):
    public_headers = {name for name in os.listdir(headers_folder) if name.endswith(".h")}
own_headers = set()
files = []
for directory, names, filenames in os.walk(tree):
    names[:] = sorted(name for name in names if name not in SKIPPED)
    for filename in sorted(filenames):
        relative = os.path.relpath(os.path.join(directory, filename), tree).replace(os.sep, "/")
        if filename.endswith(".h"):
            own_headers.add(filename)
        if filename.endswith(".swift") or filename.endswith(C_EXTENSIONS):
            files.append(relative)

for relative in files:
    with open(os.path.join(tree, relative), encoding="utf-8", errors="replace") as handle:
        text = handle.read()
    if relative.endswith(".swift"):
        if relative == "Package.swift":
            continue
        masked = scan.mask(relative, text)
        allowed = set(ANYWHERE) | own
        if relative.startswith("Tests/"):
            allowed |= IN_TESTS
        if relative.startswith(VIEW_TARGET):
            allowed |= IN_THE_VIEW_TARGET
        for match in IMPORT.finditer(masked):
            module = match.group(1)
            if module in allowed:
                continue
            if module.startswith(("ZTronDSP", "CZTronDSP")) and module not in PRODUCTS:
                message = "the external package imports the three products of ZTronDSP (%s), never a target behind them" % ", ".join(PRODUCTS)
            elif module in IN_TESTS:
                message = "SwiftUI and ZTronDSPUI are imported by the tests and under %s; Testing and ZTronDSPTesting by the tests alone" % VIEW_TARGET
            else:
                message = "the external package imports Foundation, Darwin, Accelerate, the products of ZTronDSP and its own modules"
            finding(relative, scan.line_of(text, match.start(1)), "EXT-4", "`import %s`: %s" % (module, message))
        for match in re.finditer(r"@testable\b|@_spi\b", masked):
            finding(relative, scan.line_of(text, match.start()), "EXT-4",
                    "`%s`: the external package reaches ZTronDSP through its public declarations only; what that cannot do is a finding to report" % match.group(0))
    else:
        bare = re.sub(r"/\*.*?\*/", lambda comment: re.sub(r"[^\n]", " ", comment.group(0)), text, flags=re.DOTALL)
        bare = re.sub(r"//[^\n]*", lambda comment: " " * len(comment.group(0)), bare)
        for match in INCLUDE.finditer(bare):
            quote, name = match.group(1), match.group(2).strip()
            base = name.split("/")[-1]
            of_the_package = base.startswith("ztd") or "ZTronDSP" in name
            if quote == "<" and not of_the_package:
                continue                                   # a system header
            if "/" not in name and (name in own_headers or name in public_headers):
                continue
            finding(relative, scan.line_of(text, match.start()), "EXT-4",
                    "`#include %s`: a C target of the external package includes its own headers and the public headers of ZTronDSP (Sources/CZTronDSP/include), by name" % name)

# The bans of the package's own lint, over this tree. SwiftUI is what the view target is for.
lint = subprocess.run([sys.executable, os.path.join(root, "Scripts", "lib", "lint_bans.py"), tree], capture_output=True, text=True)
for line in lint.stdout.splitlines():
    match = re.match(r"^(.+?):(\d+): \[([^\]]+)\] (.*)$", line)
    if not match:
        continue
    path, number, rule, message = match.group(1), int(match.group(2)), match.group(3), match.group(4)
    if rule == "BIND-7" and path.startswith(VIEW_TARGET):
        continue
    finding(path, number, rule, message)
if lint.returncode not in (0, 1):
    finding("Scripts/lib/lint_bans.py", 1, "LINT", "the lint did not run over the tree: %s" % (lint.stderr.strip() or lint.stdout.strip()))

unique = sorted(set(findings))
for path, line, rule, message in unique:
    print("%s:%d: [%s] %s" % (path, line, rule, message))
if unique:
    print("rules: %d violation%s (%d files)" % (len(unique), "" if len(unique) == 1 else "s", len(files)))
    sys.exit(1)
print("rules: clean (%d files: the three products alone; the bans of Scripts/lint-bans.sh, parts 1 to 4)" % len(files))
PY
}

# ---------------------------------------------------------------------------------------------
# guide
# ---------------------------------------------------------------------------------------------
step_guide() {
    python3 - "$ROOT" "$TREE" "$GUIDE" "$SPECIFICATION" <<'PY'
import os, re, sys

root, tree, guide_path, specification = sys.argv[1:5]
PREFIX = "ExternalParity/"
LABELS = ("Conform to, or use", "Runs on", "Supplies", "Latency and settling", "Threading contract")
SKIPPED = {".build", ".swiftpm", ".git", "DerivedData", "Docs", "__pycache__"}
LANGUAGE = {".swift": "swift", ".c": "c", ".h": "c"}
shown = os.path.relpath(guide_path, root) if guide_path.startswith(root + os.sep) else guide_path

findings = []


def finding(line, message):
    findings.append((line, message))


def fail(message):
    print("guide: %s" % message)
    sys.exit(1)


# The rows of §5.11.1, as the specification has them.
if not os.path.isfile(specification):
    fail("there is no specification at %s to read the rows of §5.11.1 from" % specification)
rows, state = [], 0
with open(specification, encoding="utf-8") as handle:
    for line in handle:
        if state == 0 and re.match(r"^#+\s*5\.11\.1\b", line):
            state = 1
        elif state == 1 and line.startswith("| To add |"):
            state = 2
        elif state == 2:
            if not line.startswith("|"):
                break
            cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
            if cells and not re.match(r"^:?-+", cells[0]):
                rows.append(cells[0])
if not rows:
    fail("the table of §5.11.1 was not found in %s" % specification)

if not os.path.isfile(guide_path):
    fail("there is no guide at %s" % guide_path)
with open(guide_path, encoding="utf-8") as handle:
    lines = handle.read().split("\n")

# The marked regions of the files the external package compiles.
BEGIN = re.compile(r"^\s*(?://|/\*)\s*snippet:begin\s+([A-Za-z0-9_-]+)\s*(?:\*/)?\s*$")
END = re.compile(r"^\s*(?://|/\*)\s*snippet:end\s+([A-Za-z0-9_-]+)\s*(?:\*/)?\s*$")
regions, problems = {}, []
for directory, names, filenames in os.walk(tree):
    names[:] = sorted(name for name in names if name not in SKIPPED)
    for filename in sorted(filenames):
        if os.path.splitext(filename)[1] not in LANGUAGE:
            continue
        relative = PREFIX + os.path.relpath(os.path.join(directory, filename), tree).replace(os.sep, "/")
        with open(os.path.join(directory, filename), encoding="utf-8", errors="replace") as handle:
            source = handle.read().split("\n")
        name, start = None, 0
        for number, text in enumerate(source, start=1):
            begin, end = BEGIN.match(text), END.match(text)
            if begin:
                if name is not None:
                    problems.append("%s:%d: the region %s begins inside the region %s" % (relative, number, begin.group(1), name))
                name, start = begin.group(1), number
                if (relative, name) in regions:
                    problems.append("%s:%d: the region %s is marked twice" % (relative, number, name))
            elif end:
                if name != end.group(1):
                    problems.append("%s:%d: the region %s ends, and %s was open" % (relative, number, end.group(1), name or "none"))
                else:
                    regions[(relative, name)] = source[start:number - 1]
                name = None
        if name is not None:
            problems.append("%s:%d: the region %s never ends" % (relative, start, name))
for problem in problems:
    findings.append((0, problem))

# The guide: its sections, the facts each states, and its code blocks.
SNIPPET = re.compile(r"^<!--\s*snippet:\s*(\S+?)#([A-Za-z0-9_-]+)\s*-->\s*$")
HEADING = re.compile(r"^##\s+(.*\S)\s*$")
sections, order = {}, []       # row title -> {"line", "labels", "snippets"}
current, used, blocks = None, set(), 0
index = 0
while index < len(lines):
    text = lines[index]
    heading = HEADING.match(text)
    if heading:
        current = None
        title = re.sub(r"^\d+\.\s*", "", heading.group(1)).strip().lower()
        for row in rows:
            if row.lower() == title:
                if row in sections:
                    finding(index + 1, "the row \"%s\" has a second section" % row)
                sections[row] = {"line": index + 1, "labels": set(), "snippets": 0}
                order.append(row)
                current = sections[row]
        index += 1
        continue
    if current is not None and text.startswith("|"):
        cells = [cell.strip() for cell in text.strip().strip("|").split("|")]
        if len(cells) >= 2 and cells[0] in LABELS and cells[1]:
            current["labels"].add(cells[0])
    snippet = SNIPPET.match(text)
    fence = re.match(r"^```\s*([A-Za-z0-9_+-]*)\s*$", text)
    if snippet:
        path, name = snippet.group(1), snippet.group(2)
        opening = index + 1
        while opening < len(lines) and not lines[opening].strip():
            opening += 1
        language = LANGUAGE.get(os.path.splitext(path)[1])
        if opening >= len(lines) or not re.match(r"^```\s*%s\s*$" % re.escape(language or "?"), lines[opening]):
            finding(index + 1, "the snippet %s#%s is not followed by a ```%s block" % (path, name, language or "swift"))
            index += 1
            continue
        closing = opening + 1
        while closing < len(lines) and lines[closing].rstrip() != "```":
            closing += 1
        if closing >= len(lines):
            finding(opening + 1, "the block of %s#%s is never closed" % (path, name))
            break
        block = lines[opening + 1:closing]
        blocks += 1
        if current is not None:
            current["snippets"] += 1
        if not path.startswith(PREFIX) or ".." in path.split("/"):
            finding(index + 1, "the snippet %s#%s: a path of the guide begins with %s, the package whose files are compiled and tested" % (path, name, PREFIX))
        elif (path, name) not in regions:
            there = os.path.isfile(os.path.join(tree, path[len(PREFIX):]))
            finding(index + 1, "the snippet %s#%s: %s" % (path, name, "that file marks no region of this name (// snippet:begin %s … // snippet:end %s)" % (name, name)
                                                           if there else "there is no such file"))
        else:
            used.add((path, name))
            source = regions[(path, name)]
            if block != source:
                at = next((n for n in range(min(len(block), len(source))) if block[n] != source[n]), min(len(block), len(source)))
                ours = block[at] if at < len(block) else "(the block ends)"
                theirs = source[at] if at < len(source) else "(the region ends)"
                finding(opening + 2 + at, "the block differs from %s#%s at its line %d: the guide has `%s`, the compiled source `%s`"
                        % (path, name, at + 1, ours.strip(), theirs.strip()))
        index = closing + 1
        continue
    if fence and fence.group(1).lower() in ("swift", "c", "objc", "objective-c", "cpp", "c++", ""):
        closing = index + 1
        while closing < len(lines) and lines[closing].rstrip() != "```":
            closing += 1
        finding(index + 1, "a code block that no compiled file backs: put `<!-- snippet: %s<file>#<region> -->` before it, or mark it ```text" % PREFIX)
        index = closing + 1
        continue
    if fence:
        closing = index + 1
        while closing < len(lines) and lines[closing].rstrip() != "```":
            closing += 1
        index = closing + 1
        continue
    index += 1

for row in rows:
    if row not in sections:
        finding(1, "there is no section for the row \"%s\" of §5.11.1 (a heading `## <number>. %s`)" % (row, row))
        continue
    section = sections[row]
    for label in LABELS:
        if label not in section["labels"]:
            finding(section["line"], "the section \"%s\" does not say: %s (a table row `| %s | … |`)" % (row, label, label))
    if section["snippets"] == 0:
        finding(section["line"], "the section \"%s\" shows no code of a compiled example" % row)
if [row for row in order] != [row for row in rows if row in sections]:
    finding(1, "the sections do not follow the order of the rows of §5.11.1")
for key in sorted(regions):
    if key not in used:
        findings.append((0, "%s: the marked region %s is not shown in the guide" % key))

for line, message in sorted(findings):
    print("%s:%d: [GUIDE] %s" % (shown, line, message) if line else "[GUIDE] %s" % message)
if findings:
    print("guide: %d problem%s" % (len(findings), "" if len(findings) == 1 else "s"))
    sys.exit(1)
print("guide: %d rows of §5.11.1, each with its section; %d code blocks, each equal to the region of a compiled file it names (%d marked regions)"
      % (len(rows), blocks, len(regions)))
PY
}

# ---------------------------------------------------------------------------------------------
# build, test, fixtures, release, audits, speed
# ---------------------------------------------------------------------------------------------
step_build() {
    local log="$LOGS/build.log"
    xcode "$log" Debug build-for-testing
    local status=$?
    if [ "$status" -ne 0 ]; then
        say "the Debug build failed (xcodebuild exit $status); the log is $log"
        problems "$log" | indent
        return 1
    fi
    say "built for testing, Debug"
}

step_test() {
    local log="$LOGS/test.log" status
    built Debug || { say "there is no Debug build under $DERIVED: run the step build first"; return 1; }
    XCENV=()
    if [ -n "${ZTD_EXTERNAL_SEEDED_VIOLATION:-}" ]; then
        say "a violation is seeded on purpose: ${ZTD_EXTERNAL_SEEDED_VIOLATION}"
        XCENV=("TEST_RUNNER_ZTD_EXTERNAL_SEEDED_VIOLATION=${ZTD_EXTERNAL_SEEDED_VIOLATION}")
    fi
    xcode "$log" Debug test-without-building
    status=$?
    XCENV=()
    # What the suites measured where they compare within a tolerance, not bit for bit.
    grep -a "^PARITY " "$log" | awk '!seen[$0]++' | indent
    verdict "$log" "$status"
}

step_fixtures() {
    local log="$LOGS/fixtures.log" status
    built Debug || { say "there is no Debug build under $DERIVED: run the step build first"; return 1; }
    # A fixture is type-checked by swiftc alone, which is told where the modules are and not where
    # their headers are: the C modules of the external package include the kernel ABI by name.
    env CPATH="$ROOT/Sources/CZTronDSP/include${CPATH:+:$CPATH}" TMPDIR="$DERIVED/tmp" ZTD_DERIVED="$DERIVED" ZTD_CONFIG=Debug \
        "$FIXTURES" --valid "$TREE/Tests/CompileFixtures/valid" --invalid "$TREE/Tests/CompileFixtures/invalid" > "$log" 2>&1
    status=$?
    cat "$log" | indent
    case "$status" in
        0) return 0 ;;
        2) say "the fixtures could not be checked: no build, or no fixture folder" ;;
        3) say "no fixture was found under $TREE/Tests/CompileFixtures" ;;
        *) say "a fixture misbehaves" ;;
    esac
    return 1
}

step_release() {
    local log="$LOGS/release.log"
    xcode "$log" Release build-for-testing
    local status=$?
    if [ "$status" -ne 0 ]; then
        say "the Release build failed (xcodebuild exit $status); the log is $log"
        problems "$log" | indent
        return 1
    fi
    say "built for testing, Release"
}

step_audits() {
    local log="$LOGS/audits.log" status filters=() suite
    built Release || { say "there is no Release build under $DERIVED: run the step release first"; return 1; }
    for suite in $AUDIT_SUITES; do filters+=("-only-testing:$suite"); done
    XCENV=()
    xcode "$log" Release test-without-building "${filters[@]}"
    status=$?
    verdict "$log" "$status"
}

step_speed() {
    local launch=1 log report status
    built Release || { say "there is no Release build under $DERIVED: run the step release first"; return 1; }
    while [ "$launch" -le "$launches" ]; do
        log="$LOGS/speed-$launch.log"; report="$DERIVED/speed-$launch.json"
        rm -f "$report"
        # A benchmark run: the suite by itself, one test at a time, and somewhere to record. Only
        # then does the suite hold its figures against the bound.
        XCENV=("TEST_RUNNER_ZTD_BENCHMARK_OUTPUT=$report")
        xcode "$log" Release test-without-building -parallel-testing-enabled NO "-only-testing:$SPEED_SUITE"
        status=$?
        XCENV=()
        say "launch $launch of $launches:"
        grep -a -E "^SPEED .* against " "$log" | awk '!seen[$0]++' | indent
        if verdict "$log" "$status"; then
            if [ -s "$report" ]; then
                cp "$report" "$DERIVED/speed.json"
                say "every stage ran within its bound; the figures are in $DERIVED/speed.json"
                return 0
            fi
            say "the suite passed and recorded nothing: it did not run as a benchmark, so its bounds were not held"
        fi
        launch=$((launch + 1))
    done
    say "the speed check did not hold in $launches launch$([ "$launches" -eq 1 ] || echo "es")"
    return 1
}

# ---------------------------------------------------------------------------------------------

overall=0; results=""
for current in $STEPS; do
    case " $wanted " in *" $current "*) ;; *) continue ;; esac
    printf '\nexternal-parity: ===== %s =====\n' "$current"
    began=$SECONDS
    if "step_$current" 2>&1; then
        say "ok ($((SECONDS - began)) s)"
        results="$results$current passed
"
    else
        say "FAILED ($((SECONDS - began)) s)"
        results="$results$current FAILED
"
        overall=1
        [ "$keep_going" -eq 1 ] || break
    fi
done

printf '\nexternal-parity: ===== summary =====\n'
printf '%s' "$results" | while read -r name result; do printf 'external-parity: %-9s %s\n' "$name" "$result"; done
if [ "$overall" -ne 0 ]; then
    echo "external-parity: FAILED"
    exit 1
fi
echo "external-parity: passed"
exit 0
