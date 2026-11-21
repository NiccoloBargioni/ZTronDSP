"""The engine of Scripts/lint-bans.sh: the textual bans of the specification, in four parts.

    Part 1 (WP-002)  UB-1, UB-2, UB-3, SZ-2      the UIKit boundary, as UB-5 mechanises it, under
                                                 Sources/ and in the gallery's application; no
                                                 scale read off the layer in ZTronDSPUI
    Part 2 (WP-010)  RT-7(4), ATT-2              hot-path bans, `for … in` among them (CR-002); no
                                                 branching on a source's type
    Part 3 (WP-011)  APR-1, APR-2, BIND-7, EXT-1 approval-gated API; the SwiftUI boundary; hidden channels,
                                                 the gallery's application included
    Part 4 (WP-012)  API-6, IMM-1, IMM-2, VIS-1, §9.2, COV-4(a)
                                                 configuration-object names; the registers; the stored
                                                 `var`s of public structs (WP-909)

    lint_bans.py [--part N]… [--data DIR] [ROOT]

ROOT is the tree to lint: the package, or a fixture tree shaped like it. The registers are read
from ROOT/Docs/Process. A violation is printed as `path:line: [RULE] message`.
Exit status: 0 clean, 1 violations, 2 usage error.
"""

import fnmatch
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import source_scan as scan  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE_ROOT = os.path.normpath(os.path.join(HERE, "..", ".."))

SOURCE_EXTENSIONS = (".swift",) + scan.C_EXTENSIONS
SKIPPED_DIRECTORIES = {".build", ".git", ".swiftpm", "DerivedData", "Docs", "node_modules", ".venv", "__pycache__"}
# Fixture trees hold seeded violations on purpose.
SKIPPED_PREFIXES = ("Tests/Fixtures/", "Tests/CompileFixtures/")

BRIDGE_FILE = "Sources/ZTronDSPUI/Bridge/MetalViewRepresentable.swift"
UI_TARGET = "Sources/ZTronDSPUI/"
# The gallery's application target is written as an app on the package is: SwiftUI alone, so the
# UIKit boundary holds in it with no bridge exception (UB-1, UB-2), and it reaches the package
# through public declarations only (EXT-1: no `@testable import`; its hosted tests may).
GALLERY_APP = "Examples/ZTronDSPGallery/Gallery/"
BINDINGS_GROUP = "Sources/ZTronDSPCore/Bindings/"
ENGINE_GROUP = "Sources/ZTronDSPCore/Engine/"
# Targets whose production code never uses `package` access (EXT-1, VIS-1).
NO_PACKAGE_ACCESS = ("Sources/ZTronDSPDesign/", "Sources/ZTronDSPMetal/", "Sources/ZTronDSPAnalysis/",
                     "Sources/ZTronDSPIO/", "Sources/ZTronDSPUI/", "Sources/ZTronDSP/")

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SWIFT_IMPORT = re.compile(
    r"^[ \t]*(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?[ \t]+)*(?:(?:public|internal|private|fileprivate|package)[ \t]+)?"
    r"import[ \t]+(?:(struct|class|enum|protocol|typealias|func|var|let)[ \t]+)?([A-Za-z_]\w*)(?:\.([A-Za-z_][\w.]*))?",
    re.MULTILINE)
C_IMPORT = re.compile(r"^[ \t]*#[ \t]*(?:import|include)[ \t]*[<\"]([A-Za-z_]\w*)/[^\n]*|^[ \t]*@import[ \t]+([A-Za-z_]\w*)[^\n]*", re.MULTILINE)


class Finding:
    def __init__(self, path, line, rule, message):
        self.path, self.line, self.rule, self.message = path, line, rule, message

    def __str__(self):
        return "%s:%d: [%s] %s" % (self.path, self.line, self.rule, self.message)


class SourceFile:
    def __init__(self, root, relative):
        self.relative = relative
        with open(os.path.join(root, relative), encoding="utf-8", errors="replace") as handle:
            self.text = handle.read()
        self._masked = None

    @property
    def masked(self):
        if self._masked is None:
            self._masked = scan.mask(self.relative, self.text)
        return self._masked

    @property
    def is_swift(self):
        return self.relative.endswith(".swift")

    def line(self, offset):
        return scan.line_of(self.text, offset)


def discover(root):
    files = []
    for directory, names, filenames in os.walk(root):
        names[:] = sorted(n for n in names if n not in SKIPPED_DIRECTORIES)
        for filename in sorted(filenames):
            if not filename.endswith(SOURCE_EXTENSIONS):
                continue
            relative = os.path.relpath(os.path.join(directory, filename), root).replace(os.sep, "/")
            if relative.startswith(SKIPPED_PREFIXES):
                continue
            files.append(SourceFile(root, relative))
    return files


def read_list(path):
    """Sections of a data file: `[name]` headings, one entry per line, `#` comments."""
    sections, current = {}, None
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            if line.startswith("[") and line.endswith("]"):
                current = line[1:-1]
                sections.setdefault(current, [])
            else:
                sections.setdefault(current, []).append(line)
    return sections


def split_row(line):
    text = line.strip()
    text = text[1:] if text.startswith("|") else text
    text = text[:-1] if text.endswith("|") else text
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


def read_register(root, name, first_column):
    """Rows of the register table whose header starts with `first_column`.

    Returns (rows, path relative to root, exists). A row is {column: value, "_line": n}; code
    spans around a value are removed.
    """
    relative = "Docs/Process/" + name
    path = os.path.join(root, relative)
    if not os.path.isfile(path):
        return [], relative, False
    rows, header = [], None
    with open(path, encoding="utf-8") as handle:
        for number, line in enumerate(handle.read().split("\n"), start=1):
            if not line.startswith("|"):
                header = None
                continue
            cells = split_row(line)
            if header is None:
                header = cells if cells and cells[0] == first_column else False
                continue
            if header is False or re.match(r"^\|\s*:?-+", line):
                continue
            row = {column: (cells[index].strip("`").strip() if index < len(cells) else "") for index, column in enumerate(header)}
            row["_line"] = number
            rows.append(row)
    return rows, relative, True


# ---------------------------------------------------------------------------------------------
# Part 1 — the UIKit boundary (UB-1, UB-2, UB-3)
# ---------------------------------------------------------------------------------------------

def part_1(files, data, findings):
    ns_names = set(read_list(os.path.join(data, "uikit-ns-names.txt")).get(None, []))
    bridge = read_list(os.path.join(data, "bridge-allowlist.txt"))
    bridge_identifiers = set(bridge.get("identifiers", []))
    bridge_imports = set(bridge.get("imports", []))
    bridge_members = set(bridge.get("members", []))

    for source in files:
        in_sources = source.relative.startswith("Sources/")
        if not (in_sources or source.relative.startswith(GALLERY_APP)):
            continue
        masked = source.masked
        is_bridge = source.relative == BRIDGE_FILE
        where = "under Sources/" if in_sources else "in the gallery's application"

        # UB-1: the two imports.
        if source.is_swift:
            for match in SWIFT_IMPORT.finditer(masked):
                if match.group(2) in ("UIKit", "AppKit"):
                    findings.append(Finding(source.relative, source.line(match.start(2)), "UB-1",
                                            "import %s: no file %s imports UIKit or AppKit" % (match.group(2), where)))
                elif is_bridge and match.group(2) not in bridge_imports:
                    findings.append(Finding(source.relative, source.line(match.start(2)), "UB-2",
                                            "import %s: the bridge file imports %s only" % (match.group(2), " and ".join(sorted(bridge_imports)))))
        else:
            for match in C_IMPORT.finditer(masked):
                module = match.group(1) or match.group(2)
                if module in ("UIKit", "AppKit"):
                    findings.append(Finding(source.relative, source.line(match.start()), "UB-1",
                                            "%s is imported: no file %s imports UIKit or AppKit" % (module, where)))

        # UB-2: identifiers.
        import_spans = [(m.start(), m.end()) for m in (SWIFT_IMPORT if source.is_swift else C_IMPORT).finditer(masked)]
        for match in IDENTIFIER.finditer(masked):
            name = match.group(0)
            if any(start <= match.start() < end for start, end in import_spans):
                continue   # reported as UB-1
            # UB-5: "UI followed by a capital letter". UIKit's names are camel case (UIView) or
            # its own macros (UIKIT_EXTERN); the all-capital names of <stdint.h> (UINT32_MAX,
            # UINT8_C) are neither, and UInt32 has no capital after "UI" at all.
            looks_uikit = (len(name) > 2 and name.startswith("UI") and name[2].isupper()
                           and (any(character.islower() for character in name) or name.startswith("UIKIT")))
            if looks_uikit:
                if is_bridge and name in bridge_identifiers:
                    continue
                findings.append(Finding(source.relative, source.line(match.start()), "UB-2",
                                        "%s: a UIKit-style name (UI + capital) is not named %s%s" % (
                                            name, where, ", and the bridge file may name only " + ", ".join(sorted(bridge_identifiers)) if is_bridge else "")))
            elif name in ns_names:
                findings.append(Finding(source.relative, source.line(match.start()), "UB-2",
                                        "%s is declared by UIKit and is not named %s" % (name, where)))
            elif name == "MTKView" and not is_bridge:
                findings.append(Finding(source.relative, source.line(match.start()), "UB-2",
                                        "MTKView is a UIView; it is named only in %s" % BRIDGE_FILE))

        # SZ-2 (CR-027): the drawable is sized by the display scale SwiftUI reports. The layer's
        # `contentsScale` is rewritten by the system whenever a drawable is sized by hand, so the
        # name does not occur in ZTronDSPUI's code (comments may explain why).
        if source.relative.startswith(UI_TARGET):
            for match in re.finditer(r"\bcontentsScale\b", masked):
                findings.append(Finding(source.relative, source.line(match.start()), "SZ-2",
                                        "`contentsScale` is not named in the code of ZTronDSPUI: the drawable is sized by the "
                                        "display scale SwiftUI reports, never by a scale read off the layer"))

        # UB-3: in the bridge file the view is `metalView`, and only MetalKit's members are used on it.
        if is_bridge:
            for match in re.finditer(r"\bmetalView\s*[?!]?\s*\.\s*([A-Za-z_]\w*)", masked):
                if match.group(1) not in bridge_members:
                    findings.append(Finding(source.relative, source.line(match.start(1)), "UB-3",
                                            "metalView.%s is not on the list of MetalKit members the bridge may use" % match.group(1)))
            for match in re.finditer(r"\b([A-Za-z_]\w*)\s*:\s*(?:inout\s+)?MTKView\b", masked):
                if match.group(1) != "metalView":
                    findings.append(Finding(source.relative, source.line(match.start(1)), "UB-3",
                                            "the view is called `%s`: the bridge refers to it only by the name `metalView`" % match.group(1)))
            for match in re.finditer(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*MTKView\s*\(", masked):
                if match.group(1) != "metalView":
                    findings.append(Finding(source.relative, source.line(match.start(1)), "UB-3",
                                            "the view is called `%s`: the bridge refers to it only by the name `metalView`" % match.group(1)))
            for match in re.finditer(r"\bMTKView\s*\(", masked):
                depth, cursor = 0, match.end() - 1
                while cursor < len(masked):
                    depth += {"(": 1, ")": -1}.get(masked[cursor], 0)
                    cursor += 1
                    if depth == 0:
                        break
                if re.match(r"\s*[?!]?\s*\.", masked[cursor:cursor + 8]):
                    findings.append(Finding(source.relative, source.line(match.start()), "UB-3",
                                            "a member is used on the view as it is created: name it `metalView` first"))


# ---------------------------------------------------------------------------------------------
# Part 2 — hot-path bans (RT-7, item 4) and the source-type check (ATT-2)
# ---------------------------------------------------------------------------------------------

HOT_BANS = [
    (re.compile(r"\bDispatchSemaphore\b"), "DispatchSemaphore"),
    (re.compile(r"\bNSLock\b"), "NSLock"),
    (re.compile(r"\bos_unfair_lock\w*"), "os_unfair_lock"),
    (re.compile(r"\bobjc_sync_enter\b"), "objc_sync_enter"),
    (re.compile(r"\.\s*sync\s*[({]"), ".sync {"),
    (re.compile(r"\bTask\s*[({]|\bTask\s*\.\s*detached\b"), "Task {"),
    (re.compile(r"\bawait\b"), "await"),
    (re.compile(r"(?<![A-Za-z0-9_])print\s*\("), "print("),
    (re.compile(r"\bLogger\b"), "Logger"),
]

SOURCE_CAST = re.compile(
    r"(\bis\b|\bas\?|\bas!)\s*\(?\s*(?:any\s+|some\s+)?((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*Source)\b(?![\w<])"
    r"|\bcase\s+(?:let|var)\s+[A-Za-z_]\w*\s+(as)\s+(?:any\s+)?((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*Source)\b(?![\w<])")


def for_in_loops(masked):
    """Offsets of the `for` keyword of every `for … in` loop in masked Swift.

    `for` and `in` are also argument labels (`value(for: key, in: table)`). A label sits inside
    parentheses; the keyword of a loop sits directly inside braces, or at the top level.
    """
    found, tokens, open_brackets = [], scan.tokens(masked), []
    closers = {")": "(", "]": "[", "}": "{"}
    for index, (text, offset) in enumerate(tokens):
        if text in ("(", "[", "{"):
            open_brackets.append(text)
        elif text in closers:
            if open_brackets:
                open_brackets.pop()
        elif text == "for" and (not open_brackets or open_brackets[-1] == "{"):
            depth, cursor = 0, index + 1
            while cursor < len(tokens):
                word = tokens[cursor][0]
                if word in ("(", "["):
                    depth += 1
                elif word in (")", "]"):
                    depth -= 1
                    if depth < 0:
                        break
                elif depth == 0 and word in ("{", "}", ";"):
                    break
                elif depth == 0 and word == "in":
                    found.append(offset)
                    break
                cursor += 1
    return found


def is_hot(relative):
    parts = relative.split("/")[:-1]
    if not relative.startswith("Sources/"):
        return False
    if "Kernels" in parts or "Nodes" in parts:
        return True
    return any(parts[index] == "Engine" and parts[index + 1] == "Run" for index in range(len(parts) - 1))


def part_2(files, data, findings):
    for source in files:
        masked = source.masked
        if is_hot(source.relative):
            for pattern, name in HOT_BANS:
                for match in pattern.finditer(masked):
                    if name == "print(" and re.search(r"\bfunc\s+$", masked[max(0, match.start() - 16):match.start()]):
                        continue
                    findings.append(Finding(source.relative, source.line(match.start()), "RT-7",
                                            "`%s` is banned in a hot directory (Kernels/, Nodes/, Engine/Run/)" % name))
            if source.is_swift:
                # CR-002: measured on Swift 6.4, a `for … in` loop allocates on every iteration at
                # -Onone, so the allocation audit would hold in Release builds only.
                for offset in for_in_loops(masked):
                    findings.append(Finding(source.relative, source.line(offset), "RT-7",
                                            "`for … in` is banned in a hot directory: at -Onone the loop allocates on every iteration, "
                                            "which breaks the allocation audit in Debug builds; write a `while` loop (CR-002)"))
        if source.relative.startswith(ENGINE_GROUP) and source.is_swift:
            for match in SOURCE_CAST.finditer(masked):
                operator = match.group(1) or ("case … " + match.group(3))
                type_name = match.group(2) or match.group(4)
                findings.append(Finding(source.relative, source.line(match.start()), "ATT-2",
                                        "`%s %s`: engine code does not branch on the concrete source type; SourceAdapter is the one place that does" % (operator, type_name)))


# ---------------------------------------------------------------------------------------------
# Part 3 — approval-gated API (APR-1, APR-2), the SwiftUI boundary (BIND-7), hidden channels (EXT-1)
# ---------------------------------------------------------------------------------------------

GATED_NAMES = {
    "AnyView": "AnyView",
    "ObservableObject": "ObservableObject",
    "Published": "@Published",
    "StateObject": "@StateObject",
    "ObservedObject": "@ObservedObject",
    "EnvironmentObject": "@EnvironmentObject",
    "Publisher": "Publisher",
    "AnyPublisher": "AnyPublisher",
    "AnyCancellable": "AnyCancellable",
    "PassthroughSubject": "PassthroughSubject",
    "CurrentValueSubject": "CurrentValueSubject",
}
GATED_CALLS = [(re.compile(r"\.\s*sink\s*[({]"), ".sink"), (re.compile(r"\.\s*onReceive\s*\("), ".onReceive")]
GATED_API = sorted(set(GATED_NAMES.values()) | {"import Combine", ".sink", ".onReceive"})

PACKAGE_MODIFIER = re.compile(
    r"\bpackage\s*(?:\(\s*set\s*\)\s*)?(?=(?:func|var|let|struct|class|enum|protocol|extension|typealias|init|subscript|static|final|actor|"
    r"import|nonisolated|mutating|override|convenience|required|lazy|weak|unowned|indirect|distributed|consuming|borrowing|macro|"
    r"public|open|internal|private|fileprivate)\b)")


def change_request_approved(root, number):
    """(approved, reason) for Docs/Process/changes/<number>.md."""
    path = os.path.join(root, "Docs", "Process", "changes", number + ".md")
    if not os.path.isfile(path):
        return False, "Docs/Process/changes/%s.md does not exist" % number
    fields = {}
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("|"):
                cells = split_row(line)
                if len(cells) == 2:
                    fields[cells[0].lower()] = cells[1].strip()
    if fields.get("status", "").lower() != "approved":
        return False, "%s is '%s', not Approved" % (number, fields.get("status", "without a status") or "without a status")
    if not fields.get("approved by"):
        return False, "%s names nobody under 'Approved by'" % number
    if not re.match(r"^\d{4}-\d{2}-\d{2}$", fields.get("approved on", "")):
        return False, "%s carries no date under 'Approved on'" % number
    return True, ""


def part_3(files, data, findings, root):
    rows, register, exists = read_register(root, "approvals.md", "Change request")
    valid = []
    for row in rows:
        number, api, scope = row.get("Change request", ""), row.get("API", ""), row.get("Scope", "")
        problems = []
        if not re.match(r"^CR-\d{3}$", number):
            problems.append("it names no change request (CR-nnn)")
        else:
            approved, reason = change_request_approved(root, number)
            if not approved:
                problems.append(reason)
        if api not in GATED_API:
            problems.append("'%s' is not an approval-gated name (%s)" % (api, ", ".join(GATED_API)))
        if not scope:
            problems.append("it has no scope")
        if problems:
            findings.append(Finding(register, row["_line"], "APR-2",
                                    "this allow-list entry counts for nothing: " + "; ".join(problems)))
        else:
            row["_used"] = False
            valid.append(row)

    def allowed(api, relative):
        for row in valid:
            if row["API"] == api and fnmatch.fnmatchcase(relative, row["Scope"]):
                row["_used"] = True
                return True
        return False

    for source in files:
        if not source.is_swift:
            continue
        masked = source.masked
        relative = source.relative

        # APR-1, everywhere: production targets, tests, examples.
        hits = []
        for match in SWIFT_IMPORT.finditer(masked):
            if match.group(2) == "Combine":
                hits.append((match.start(2), "import Combine"))
        for match in IDENTIFIER.finditer(masked):
            if match.group(0) in GATED_NAMES:
                hits.append((match.start(), GATED_NAMES[match.group(0)]))
        for pattern, api in GATED_CALLS:
            for match in pattern.finditer(masked):
                hits.append((match.start(), api))
        for offset, api in sorted(hits):
            if not allowed(api, relative):
                findings.append(Finding(relative, source.line(offset), "APR-1",
                                        "`%s` needs a change request approved by the owner and an entry in Docs/Process/approvals.md" % api))

        # EXT-1 in the gallery's application, as in any app on the package: public declarations only.
        if relative.startswith(GALLERY_APP):
            for match in re.finditer(r"@testable\b", masked):
                findings.append(Finding(relative, source.line(match.start()), "EXT-1",
                                        "`@testable import` is not used in the gallery's application: it reaches the package "
                                        "through its public API, as an app does (its hosted tests may)"))

        if not relative.startswith("Sources/"):
            continue

        # BIND-7: SwiftUI outside ZTronDSPUI is the one name Binding, in ZTronDSPCore/Bindings/.
        in_ui = relative.startswith(UI_TARGET)
        in_bindings = relative.startswith(BINDINGS_GROUP)
        if not in_ui:
            for match in SWIFT_IMPORT.finditer(masked):
                if match.group(2) != "SwiftUI":
                    continue
                kind, member = match.group(1), match.group(3)
                if kind == "struct" and member == "Binding" and in_bindings:
                    continue
                written = "import %sSwiftUI%s" % (kind + " " if kind else "", "." + member if member else "")
                findings.append(Finding(relative, source.line(match.start(2)), "BIND-7",
                                        "`%s`: outside ZTronDSPUI the only SwiftUI import is `import struct SwiftUI.Binding`, under %s" % (written, BINDINGS_GROUP)))
            if not in_bindings:
                import_spans = [(m.start(), m.end()) for m in SWIFT_IMPORT.finditer(masked)]
                for match in re.finditer(r"\bBinding\b", masked):
                    if any(start <= match.start() < end for start, end in import_spans):
                        continue
                    findings.append(Finding(relative, source.line(match.start()), "BIND-7",
                                            "`Binding` is named only under %s" % BINDINGS_GROUP))

        # EXT-1: no hidden channel between the targets.
        for match in re.finditer(r"@_spi\b", masked):
            findings.append(Finding(relative, source.line(match.start()), "EXT-1",
                                    "`@_spi`: the targets reach one another through public declarations only"))
        for match in re.finditer(r"@testable\b", masked):
            findings.append(Finding(relative, source.line(match.start()), "EXT-1",
                                    "`@testable import` is not used in production code"))
        if relative.startswith(NO_PACKAGE_ACCESS):
            for match in PACKAGE_MODIFIER.finditer(masked):
                before = masked[max(0, match.start() - 1):match.start()]
                if before in (".", "`"):
                    continue
                findings.append(Finding(relative, source.line(match.start()), "EXT-1",
                                        "`package` access is not used by the production code of Design, Metal, Analysis, IO, UI or the facade"))

    for row in valid:
        if not row["_used"]:
            findings.append(Finding(register, row["_line"], "APR-2",
                                    "this allow-list entry (%s in %s) matches no code" % (row["API"], row["Scope"])))


# ---------------------------------------------------------------------------------------------
# Part 4 — configuration-object names (API-6) and the registers (IMM-1, IMM-2, VIS-1, §9.2, COV-4 a)
# ---------------------------------------------------------------------------------------------

BANNED_SUFFIXES = ("Configuration", "Options", "Settings", "Style", "Descriptor", "Specification", "Specs", "Params")
ACCESS_LEVELS = ("public", "open", "internal", "fileprivate", "private", "package")
MODIFIERS = set(ACCESS_LEVELS) | {
    "static", "class", "final", "lazy", "weak", "unowned", "nonisolated", "override", "dynamic", "mutating",
    "nonmutating", "required", "convenience", "indirect", "isolated", "consuming", "borrowing", "distributed", "optional"}
TYPE_KEYWORDS = ("struct", "class", "enum", "actor", "protocol", "extension")
ACCESSOR_NAMES = {"get", "set", "willSet", "didSet", "_read", "_modify", "unsafeAddress", "unsafeMutableAddress", "init"}
ACCESSOR_MODIFIERS = {"mutating", "nonmutating", "async", "throws", "rethrows", "consuming", "borrowing", "__consuming"}
SETTERS = {"set", "_modify", "unsafeMutableAddress"}


class Declarations:
    """Member and top-level declarations of one Swift file, read from its masked text.

    This is not a parser. It follows braces, recognises type declarations, and looks at `var`,
    `subscript`, `func`, `init` and `typealias` where they are members of a type or top-level
    declarations. That is enough to say which declarations are public, which are `open`, and
    which public properties can be set.
    """

    def __init__(self, masked):
        self.tokens = scan.tokens(masked)
        self.types = []       # (name, kind, effective access, offset)
        self.setters = []     # (symbol, offset)
        self.stored = []      # (symbol, offset, "public" | "internal"): stored `var`s of public structs
        self.opens = []       # (symbol, offset)
        self._walk()

    # --- helpers ---------------------------------------------------------------------------

    def _text(self, index):
        return self.tokens[index][0] if 0 <= index < len(self.tokens) else ""

    def _next(self, index):
        """Index of the next token that is not a newline."""
        index += 1
        while index < len(self.tokens) and self.tokens[index][0] == "\n":
            index += 1
        return index

    def _previous(self, index):
        index -= 1
        while index >= 0 and self.tokens[index][0] == "\n":
            index -= 1
        return index

    def _matching_open(self, index):
        """Index of the '(' that the ')' at `index` closes, or -1."""
        depth = 0
        while index >= 0:
            text = self.tokens[index][0]
            if text == ")":
                depth += 1
            elif text == "(":
                depth -= 1
                if depth == 0:
                    return index
            index -= 1
        return -1

    def _matching_close(self, index, opener, closer):
        depth = 0
        while index < len(self.tokens):
            text = self.tokens[index][0]
            if text == opener:
                depth += 1
            elif text == closer:
                depth -= 1
                if depth == 0:
                    return index
            index += 1
        return len(self.tokens) - 1

    def _modifiers(self, index):
        """Modifiers written before the declaration keyword at `index`.

        Returns (set of modifiers, access of the getter or None, access of the setter or None).
        """
        found, access, setter_access = set(), None, None
        cursor = self._previous(index)
        while cursor >= 0:
            text = self.tokens[cursor][0]
            if text == ")":
                opener = self._matching_open(cursor)
                before = self._previous(opener)
                inside = [self.tokens[i][0] for i in range(opener + 1, cursor)]
                if self._text(before) in ACCESS_LEVELS and inside == ["set"]:
                    setter_access = self._text(before)
                    cursor = self._previous(before)
                    continue
                if self._text(before) in ("nonisolated", "unowned") and len(inside) == 1:
                    found.add(self._text(before))
                    cursor = self._previous(before)
                    continue
                if IDENTIFIER.fullmatch(self._text(before)) and self._text(self._previous(before)) == "@":
                    found.add("@" + self._text(before))      # an attribute with arguments, `@available(…)`
                    cursor = self._previous(self._previous(before))
                    continue
                break
            if text in MODIFIERS:
                found.add(text)
                if text in ACCESS_LEVELS:
                    access = text
                cursor = self._previous(cursor)
                continue
            if IDENTIFIER.fullmatch(text) and self._text(self._previous(cursor)) == "@":
                found.add("@" + text)                         # an attribute, `@usableFromInline`
                cursor = self._previous(self._previous(cursor))
                continue
            break
        return found, access, setter_access

    # --- the walk --------------------------------------------------------------------------

    def _walk(self):
        scopes = []        # {"type": bool, "kind", "name", "access"}
        pending = None     # a type declaration waiting for the brace that opens its body
        index = 0
        count = len(self.tokens)

        def member_level():
            return not scopes or scopes[-1]["type"]

        def default_access():
            if scopes and scopes[-1]["type"]:
                scope = scopes[-1]
                if scope["kind"] in ("extension", "protocol") and scope["access"] in ("public", "open"):
                    return "public"
            return "internal"

        def qualified(name):
            # The innermost type's name is already qualified (`Outer.Inner`), and an extension's
            # is the name of the type it extends: the member hangs off that alone.
            chain = [scope["name"] for scope in scopes if scope["type"]][-1:]
            return ".".join(chain + [name]) if name else ".".join(chain)

        while index < count:
            text, offset = self.tokens[index]
            if text == "{":
                if pending is not None:
                    scopes.append(pending)
                    pending = None
                else:
                    scopes.append({"type": False})
            elif text == "}":
                if scopes:
                    scopes.pop()
            elif text in TYPE_KEYWORDS and member_level() and pending is None and self._text(index - 1) != ".":
                following = self._next(index)
                name_token = self._text(following)
                is_modifier = text == "class" and (name_token in ("func", "var", "let", "subscript", "override", "final") or self._text(index - 1) in (":", ","))
                if IDENTIFIER.fullmatch(name_token) and not is_modifier and name_token not in ("func", "var", "let"):
                    name, cursor = name_token, following + 1
                    while self._text(cursor) == "." and IDENTIFIER.fullmatch(self._text(cursor + 1)):
                        name += "." + self._text(cursor + 1)
                        cursor += 2
                    modifiers, access, _ = self._modifiers(index)
                    effective = access or default_access()
                    pending = {"type": True, "kind": text, "name": qualified(name) if text != "extension" else name, "access": effective}
                    if text != "extension":
                        self.types.append((pending["name"], text, effective, offset))
                        if "open" in modifiers:
                            self.opens.append((pending["name"], offset))
                    index = cursor - 1
            elif text == "typealias" and member_level():
                name_token = self._text(self._next(index))
                if IDENTIFIER.fullmatch(name_token):
                    _, access, _ = self._modifiers(index)
                    self.types.append((qualified(name_token), "typealias", access or default_access(), offset))
            elif text == "var" and member_level():
                name_index = self._next(index)
                name = self._text(name_index)
                if IDENTIFIER.fullmatch(name):
                    modifiers, access, setter_access = self._modifiers(index)
                    effective = access or default_access()
                    if "open" in modifiers:
                        self.opens.append((qualified(name), offset))
                    if effective in ("public", "open") and setter_access is None and self._variable_can_be_set(name_index + 1):
                        self.setters.append((qualified(name), offset))
                    # A stored `var` of a public struct (IMM-1, IMM-2): public whatever its setter, or
                    # with a setter the module can reach (internal or package). A private setter is the
                    # type's own business; a public setter is already one of `setters`. A
                    # `@usableFromInline` one is how VIS-1 writes the internals of a toolkit primitive or
                    # a frame accessor, which its `@inlinable` code sets: state (IMM-3), not a value.
                    scope = scopes[-1] if scopes and scopes[-1]["type"] else None
                    if (scope is not None and scope["kind"] == "struct" and scope["access"] in ("public", "open")
                            and not ({"static", "class"} & modifiers) and self._variable_is_stored(name_index + 1)):
                        if effective in ("public", "open"):
                            if setter_access is not None:
                                self.stored.append((qualified(name), offset, "public"))
                        elif (effective in ("internal", "package") and setter_access in (None, "internal", "package")
                                and "@usableFromInline" not in modifiers):
                            self.stored.append((qualified(name), offset, "internal"))
            elif text == "subscript" and member_level() and self._text(self._next(index)) in ("(", "<"):
                modifiers, access, setter_access = self._modifiers(index)
                effective = access or default_access()
                if "open" in modifiers:
                    self.opens.append((qualified("subscript"), offset))
                if effective in ("public", "open") and setter_access is None and self._subscript_can_be_set(index + 1):
                    self.setters.append((qualified("subscript"), offset))
            elif text in ("func", "init") and member_level():
                modifiers, _, _ = self._modifiers(index)
                if "open" in modifiers:
                    name = self._text(self._next(index)) if text == "func" else "init"
                    self.opens.append((qualified(name), offset))
            index += 1

    # --- can a property be set? ---------------------------------------------------------------

    def _variable_can_be_set(self, index):
        """`index` is the token after the property's name."""
        count = len(self.tokens)
        depth = 0
        cursor = index
        while cursor < count:
            text = self.tokens[cursor][0]
            if text in ("(", "[", "<"):
                depth += 1
            elif text in (")", "]", ">"):
                depth -= 1
                if depth < 0:
                    return True
            elif depth == 0:
                if text == "=":
                    return True                       # stored, with an initial value
                if text == "{":
                    return self._block_has_setter(cursor)
                if text in (",", ";", "}"):
                    return True                       # stored, no initial value
                if text == "\n":
                    following = self._next(cursor)
                    after = self._text(following)
                    if after == "{":
                        return self._block_has_setter(following)
                    if after == "=":
                        return True
                    return True                       # stored, no initial value
            cursor += 1
        return True

    def _variable_is_stored(self, index):
        """`index` is the token after the property's name. A stored property has no accessor
        block, or a block of observers only (`willSet`, `didSet`)."""
        count = len(self.tokens)
        depth = 0
        cursor = index
        while cursor < count:
            text = self.tokens[cursor][0]
            if text in ("(", "[", "<"):
                depth += 1
            elif text in (")", "]", ">"):
                if text == ">" and self._text(cursor - 1) == "-":
                    cursor += 1                       # the arrow of a function type
                    continue
                depth -= 1
                if depth < 0:
                    return True
            elif depth == 0:
                if text == "=":
                    return True                       # an initial value: stored
                if text == "{":
                    return self._block_is_observers(cursor)
                if text in (",", ";", "}"):
                    return True
                if text == "\n":
                    following = self._next(cursor)
                    if self._text(following) == "{":
                        return self._block_is_observers(following)
                    return True
            cursor += 1
        return True

    def _block_is_observers(self, open_index):
        close = self._matching_close(open_index, "{", "}")
        outline, cursor = [], open_index + 1
        while cursor < close:
            text = self.tokens[cursor][0]
            if text == "{":
                cursor = self._matching_close(cursor, "{", "}")
                outline.append("BLOCK")
            elif text == "(":
                cursor = self._matching_close(cursor, "(", ")")
                outline.append("PAREN")
            elif text != "\n":
                outline.append(text)
            cursor += 1
        if not outline:
            return False
        position = 0
        while position < len(outline):
            if outline[position] not in ("willSet", "didSet"):
                return False
            position += 1
            if position < len(outline) and outline[position] == "PAREN":
                position += 1
            if position >= len(outline) or outline[position] != "BLOCK":
                return False
            position += 1
        return True

    def _subscript_can_be_set(self, index):
        count = len(self.tokens)
        cursor = index
        depth = 0
        while cursor < count:
            text = self.tokens[cursor][0]
            if text in ("(", "[", "<"):
                depth += 1
            elif text in (")", "]", ">"):
                depth -= 1
            elif depth == 0 and text == "{":
                return self._block_has_setter(cursor)
            elif depth == 0 and text == "}":
                return False
            cursor += 1
        return False

    def _block_has_setter(self, open_index):
        close = self._matching_close(open_index, "{", "}")
        outline, cursor = [], open_index + 1
        while cursor < close:
            text = self.tokens[cursor][0]
            if text == "{":
                cursor = self._matching_close(cursor, "{", "}")
                outline.append("BLOCK")
            elif text == "(":
                cursor = self._matching_close(cursor, "(", ")")
                outline.append("PAREN")
            elif text != "\n":
                outline.append(text)
            cursor += 1
        if not outline:
            return False
        # A requirement, or a list of accessors without bodies: `{ get set }`.
        if all(item in ACCESSOR_NAMES or item in ACCESSOR_MODIFIERS for item in outline):
            return any(item in SETTERS for item in outline)
        # Accessors with bodies: `{ get { … } set { … } }`, or observers on a stored property.
        names, position = [], 0
        while position < len(outline):
            while position < len(outline) and (outline[position] in ACCESSOR_MODIFIERS or outline[position] == "@"):
                position += 2 if outline[position] == "@" else 1
                if position < len(outline) and outline[position] == "PAREN" and outline[position - 2:position - 1] == ["@"]:
                    position += 1
            if position >= len(outline) or outline[position] not in ACCESSOR_NAMES:
                return False                          # an implicit getter: ordinary statements
            name = outline[position]
            position += 1
            if position < len(outline) and outline[position] == "PAREN":
                position += 1
            while position < len(outline) and outline[position] in ACCESSOR_MODIFIERS:
                position += 1
            if position >= len(outline) or outline[position] != "BLOCK":
                return False
            names.append(name)
            position += 1
        if all(name in ("willSet", "didSet") for name in names):
            return True                               # a stored property with observers
        return any(name in SETTERS for name in names)


def metal_functions(masked):
    """[(name, offset)] of the functions a Metal source defines."""
    functions, depth, header_start = [], 0, 0
    for index, character in enumerate(masked):
        if character == "{":
            if depth == 0:
                header = masked[header_start:index]
                stripped = header.strip()
                first_word = re.match(r"[A-Za-z_]\w*", stripped)
                is_function = bool(stripped) and stripped.endswith(")") or re.search(r"\)\s*(?:\[\[[^\]]*\]\]\s*)*$", stripped)
                if is_function and "=" not in stripped and not (first_word and first_word.group(0) in ("struct", "enum", "union", "namespace", "typedef", "class")):
                    cursor, level = len(header) - 1, 0
                    while cursor >= 0:
                        if header[cursor] == ")":
                            level += 1
                        elif header[cursor] == "(":
                            level -= 1
                            if level == 0:
                                break
                        cursor -= 1
                    match = re.search(r"([A-Za-z_]\w*)\s*$", header[:cursor]) if cursor > 0 else None
                    if match and match.group(1) not in ("if", "for", "while", "switch", "return", "sizeof"):
                        functions.append((match.group(1), header_start + match.start(1)))
            depth += 1
        elif character == "}":
            depth = max(0, depth - 1)
            if depth == 0:
                header_start = index + 1
        elif character == ";" and depth == 0:
            header_start = index + 1
    return functions


def match_register(findings, uses, rows, register, exists, key_columns, required, rule, describe, rule_of=None):
    """Compares what the code holds with what a register lists, in both directions.

    `uses` is [(key tuple, path, line)]. A row needs every column of `required` filled in.
    `rule_of(key)`, when given, names the rule of a use without a row; `rule` names the rest.
    """
    listed = {}
    for row in rows:
        key = tuple(row.get(column, "") for column in key_columns)
        empty = [column for column in required if not row.get(column, "")]
        if empty:
            findings.append(Finding(register, row["_line"], rule, "this register row has no %s" % " and no ".join(c.lower() for c in empty)))
            continue
        listed[key] = [row, False]
    for key, path, line in uses:
        if key in listed:
            listed[key][1] = True
        else:
            findings.append(Finding(path, line, rule_of(key) if rule_of else rule,
                                    describe(key) + ("" if exists else " (and the register %s does not exist)" % register)))
    for key, (row, used) in listed.items():
        if not used:
            findings.append(Finding(register, row["_line"], rule, "this register row (%s) matches nothing in the code" % ", ".join(key)))


def part_4(files, data, findings, root):
    setters, opens, sendables, shaders = [], [], [], []
    stored_kinds = {}   # (symbol, path) -> "public" | "internal", for the stored `var`s of public structs
    for source in files:
        if not source.relative.startswith("Sources/"):
            continue
        masked = source.masked
        if source.is_swift:
            declarations = Declarations(masked)
            for name, kind, access, offset in declarations.types:
                short = name.split(".")[-1]
                if access in ("public", "open") and short.endswith(BANNED_SUFFIXES):
                    suffix = next(s for s in BANNED_SUFFIXES if short.endswith(s))
                    findings.append(Finding(source.relative, source.line(offset), "API-6",
                                            "public %s `%s`: no public type is named like a configuration object (…%s)" % (kind, name, suffix)))
            for symbol, offset in declarations.setters:
                setters.append(((symbol, source.relative), source.relative, source.line(offset)))
            for symbol, offset, kind in declarations.stored:
                stored_kinds[(symbol, source.relative)] = kind
                setters.append(((symbol, source.relative), source.relative, source.line(offset)))
            for symbol, offset in declarations.opens:
                opens.append(((symbol, source.relative), source.relative, source.line(offset)))
            for match in re.finditer(r"@unchecked\s+Sendable\b", masked):
                header_start = max(masked.rfind("{", 0, match.start()), masked.rfind("}", 0, match.start())) + 1
                header = masked[header_start:match.start()]
                named = None
                for candidate in re.finditer(r"\b(?:class|struct|enum|actor|extension)\s+((?:[A-Za-z_]\w*\.)*[A-Za-z_]\w*)", header):
                    named = candidate.group(1)
                sendables.append(((named or "?", source.relative), source.relative, source.line(match.start())))
        elif source.relative.endswith(".metal"):
            for name, offset in metal_functions(masked):
                shaders.append(((name, source.relative), source.relative, source.line(offset)))

    def describe_mutable(key):
        kind = stored_kinds.get(key)
        if kind == "public":
            return ("`%s` is a public stored `var` of a value type: it is `let`, or it has an entry in "
                    "Docs/Process/mutable-by-design.md" % key[0])
        if kind == "internal":
            return ("`%s` is a stored `var` of a public value type that the module can set: it is `let`, "
                    "`private(set)` or `fileprivate(set)`, `@usableFromInline` when `@inlinable` code sets it (VIS-1), "
                    "or it has an entry in Docs/Process/mutable-by-design.md" % key[0])
        return "`%s` has a public setter and no entry in Docs/Process/mutable-by-design.md" % key[0]

    rows, register, exists = read_register(root, "mutable-by-design.md", "Symbol")
    match_register(findings, setters, rows, register, exists, ("Symbol", "File"), ("Symbol", "File", "Reason"), "IMM-2",
                   describe_mutable, rule_of=lambda key: "IMM-1" if stored_kinds.get(key) == "internal" else "IMM-2")

    rows, register, exists = read_register(root, "open-declarations.md", "Symbol")
    match_register(findings, opens, rows, register, exists, ("Symbol", "File"), ("Symbol", "File", "Reason"), "VIS-1",
                   lambda key: "`%s` is `open` and has no entry in Docs/Process/open-declarations.md" % key[0])

    rows, register, exists = read_register(root, "unchecked-sendable.md", "Type")
    match_register(findings, sendables, rows, register, exists, ("Type", "File"), ("Type", "File", "Threading contract"), "SEND",
                   lambda key: "`%s` is `@unchecked Sendable` and has no entry in Docs/Process/unchecked-sendable.md (§9.2)" % key[0])

    rows, register, exists = read_register(root, "shader-coverage.md", "Shader function")
    match_register(findings, shaders, rows, register, exists, ("Shader function", "File"),
                   ("Shader function", "File", "Covered by", "Kind"), "COV-4",
                   lambda key: "shader function `%s` has no entry in Docs/Process/shader-coverage.md" % key[0])
    test_text = None
    for row in rows:
        covered, kind = row.get("Covered by", ""), row.get("Kind", "")
        if not covered:
            continue
        if kind.lower() not in ("parity", "golden"):
            findings.append(Finding(register, row["_line"], "COV-4", "kind '%s' is neither parity nor golden" % kind))
        if test_text is None:
            test_text = "\n".join(source.masked for source in files if source.relative.startswith("Tests/") and source.is_swift)
        if not re.search(r"\b%s\b" % re.escape(covered.rstrip("()")), test_text):
            findings.append(Finding(register, row["_line"], "COV-4", "the test `%s` is not found under Tests/" % covered))


# ---------------------------------------------------------------------------------------------

def main(arguments):
    parts, root, data = [], None, os.path.join(PACKAGE_ROOT, "Scripts", "lint")
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--part" and index + 1 < len(arguments):
            index += 1
            if arguments[index] not in ("1", "2", "3", "4"):
                print("lint-bans: there is no part %s" % arguments[index], file=sys.stderr)
                return 2
            parts.append(int(arguments[index]))
        elif argument == "--data" and index + 1 < len(arguments):
            index += 1
            data = arguments[index]
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif argument.startswith("-"):
            print("lint-bans: unknown option %s" % argument, file=sys.stderr)
            return 2
        elif root is None:
            root = argument
        else:
            print("lint-bans: one tree at a time", file=sys.stderr)
            return 2
        index += 1
    root = os.path.abspath(root or PACKAGE_ROOT)
    if not os.path.isdir(root):
        print("lint-bans: %s is not a directory" % root, file=sys.stderr)
        return 2
    parts = sorted(set(parts)) or [1, 2, 3, 4]

    files = discover(root)
    findings = []
    if 1 in parts:
        part_1(files, data, findings)
    if 2 in parts:
        part_2(files, data, findings)
    if 3 in parts:
        part_3(files, data, findings, root)
    if 4 in parts:
        part_4(files, data, findings, root)

    seen, unique = set(), []
    for finding in sorted(findings, key=lambda f: (f.path, f.line, f.rule, f.message)):
        key = (finding.path, finding.line, finding.rule, finding.message)
        if key not in seen:
            seen.add(key)
            unique.append(finding)
    for finding in unique:
        print(finding)
    label = "part%s %s" % ("s" if len(parts) > 1 else "", ", ".join(str(p) for p in parts))
    if unique:
        print("lint-bans: %d violation%s (%s; %d files)" % (len(unique), "" if len(unique) == 1 else "s", label, len(files)))
        return 1
    print("lint-bans: clean (%s; %d files)" % (label, len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
