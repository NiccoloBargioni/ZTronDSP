"""The documentation audit (VIS-2, WP-901b): every public symbol is documented with its
threading contract, which context may call it and whether it may allocate.

    doc_audit.py audit [--graphs DIR] [--sources DIR]… [--headers DIR]… [--catalogs DIR]…
                       [--module NAME]… [--root DIR] [--report FILE]
    doc_audit.py docbuild --log FILE --archives DIR [--root DIR] [--status N]
    doc_audit.py links --archive DIR [--root DIR]

THE VOCABULARY. A threading contract is recognised by a small fixed vocabulary, and the
package's comments are written with it. A comment states a context when it names one of the
execution contexts of §4.3 by its name there:

    control context            the utility queue that designs, compiles and allocates
                               ("control or background context" names it too)
    analysis thread            the engine's thread (and the offline one, which does the same work)
    I/O thread                 Core Audio's thread: C only, RT-1
    main thread, main actor    (also written @MainActor) where bindings and views live
    background executor,       the executor of every analysis and export (BG-1);
    BackgroundWork,            "in the background" says the same
    in the background
    any thread                 a value, or a function that runs where it is called

and it states whether the code may allocate when it says one of

    allocates, may allocate, does not allocate, never allocates

("allocates nothing" and "allocates its arrays" are spellings of the first; "do not allocate"
and "never allocate", said of several things, of the last two). Case and line breaks do not
matter.

THE READING (change request CR-033, Proposed; it implements verifier A's CR-VA-4). A type's
statement of context and allocation covers its members: a member says its own contract only
where it differs (a method callable from the analysis thread only, a `process` that must not
allocate). A member that implements a protocol requirement has the requirement's contract
unless it states another. An `@available(*, unavailable)` declaration that exists only to give
a diagnostic (ORD-4) needs a comment that says so (it names ORD-4, or says "unavailable" or
"diagnostic") and no contract. Until the owner decides, every public member also carries a
`///` of its own, so that VIS-2 read as written passes too.

THE CHECKS. Findings, one line each, `path:line: [check] symbol: what is missing`:

  [no comment]   a public symbol of a Swift module, of any kind the symbol graph reports (types,
                 protocols and their requirements, initialisers, methods, properties,
                 subscripts, enum cases, type aliases, global functions, operators) has no
                 documentation comment of its own. The graphs are read as Scripts/docs.sh
                 extracts them, with -skip-inherited-docs: a comment a symbol only inherits
                 from the requirement it implements does not count here. What the compiler
                 writes itself (`init(rawValue:)` of a raw-valued enumeration, `init(from:)` of
                 a Decodable type) has no declaration to comment: it is counted apart.
  [no contract]  a public type (structure, class, enumeration, actor, protocol, nested ones
                 included), a global function or operator, or a member that a module adds to a
                 type of another module, has a comment that names no context of the vocabulary,
                 or says nothing on allocation. Exempt: a member of another module's type that
                 implements a requirement whose comment, or whose protocol's comment, states
                 both halves.
  [source]       a `public` or `open` declaration in the sources has no `///` comment directly
                 above it (attributes may stand between). This reads what the symbol graph
                 leaves out, the unavailable ORD-4 overloads first, and is the textual reading
                 the verifiers' scanners apply. An unavailable declaration's comment says that
                 it exists for its diagnostic.
  [C]            a function, type or macro of a public C header has no comment directly above
                 it, above the group of declarations it opens with no blank line between, or on
                 its own line. The C contract is the comment together with ZTD_NONBLOCKING:
                 ztd_base.h says a function without it belongs to the control context and may
                 allocate.
  [example]      the code of a documentation catalog (an article of a `.docc` folder) is not
                 compiled code. Every Swift block of an article follows a marker on a line of its
                 own, `<!-- snippet: <path from the package root>#<region> -->`, and holds the
                 lines of that region as they are, less their common indentation. A region is
                 marked in its file by a line `// snippet:begin <region>` before it and
                 `// snippet:end <region>` after it; the file is a test, so the code builds and
                 runs with the tests and the page cannot show code that does not.

THE DOCUMENTATION BUILD. `docbuild` reads the log of `xcodebuild docbuild` and the archives it
made: it prints each warning that names a file of the package (DocC's: unresolved or ambiguous
links, parameters documented that do not exist or left out where others are documented; and the
compiler's), once, and the count of pages each archive holds; a warning that names no file of the
package is shown as a note. It fails on a warning of the package, on a failed build (--status),
and on a build that made no archive.

THE LINKS BETWEEN THE MODULES. Each archive holds the pages of one module, so the landing page
reaches the others by a link written as a path, `[ZTronDSPCore](/documentation/ztrondspcore)`,
which DocC does not resolve. Scripts/docs.sh merges the archives into one (`docc merge`), and
`links` reads every page of that combined archive: each link to a path under /documentation/
names one of its pages, or is printed, and the run fails.

Exit status: 0 nothing found, 1 a finding, 2 usage error or unreadable input.
"""

import collections
import difflib
import json
import os
import re
import sys

CONTEXT = re.compile(
    r"control (?:or background )?context|analysis thread|I/O thread|main thread|main actor|@MainActor|"
    r"background executor|BackgroundWork|in the background|any thread", re.IGNORECASE)
ALLOCATION = re.compile(r"\ballocates\b|may allocate|does not allocate|do not allocate|never allocates?\b", re.IGNORECASE)
DIAGNOSTIC = re.compile(r"ORD-4|unavailable|diagnostic", re.IGNORECASE)

TYPE_KINDS = {"swift.struct", "swift.class", "swift.enum", "swift.actor", "swift.protocol"}
GLOBAL_FUNCTION_KINDS = {"swift.func", "swift.func.op", "swift.var"}
KIND_NAMES = {
    "swift.struct": "structure", "swift.class": "class", "swift.enum": "enumeration", "swift.actor": "actor",
    "swift.protocol": "protocol", "swift.typealias": "type alias", "swift.associatedtype": "associated type",
    "swift.init": "initialiser", "swift.method": "method", "swift.type.method": "type method",
    "swift.property": "property", "swift.type.property": "type property", "swift.subscript": "subscript",
    "swift.type.subscript": "type subscript", "swift.enum.case": "enum case", "swift.func": "function",
    "swift.func.op": "operator", "swift.var": "global variable", "swift.macro": "macro",
}

MODIFIERS = (r"(?:public|open|private\(set\)|fileprivate\(set\)|internal\(set\)|package\(set\)|static|class|final|override|"
             r"mutating|nonmutating|nonisolated|convenience|required|indirect|lazy|weak|unowned|dynamic|optional|prefix|"
             r"postfix|infix|consuming|borrowing|isolated|distributed)")
DECLARATION = re.compile(r"^(?:%s\s+)*?(?:public|open)\s+(?:%s\s+)*(func|init|deinit|var|let|struct|class|enum|protocol|typealias|"
                         r"case|subscript|actor|associatedtype|extension|macro|operator|precedencegroup)\b" % (MODIFIERS, MODIFIERS))


class Refused(Exception):
    pass


def comment_text(symbol):
    doc = symbol.get("docComment")
    if not doc:
        return ""
    return re.sub(r"\s+", " ", " ".join(line.get("text", "") for line in doc.get("lines", []))).strip()


def states_contract(text):
    return bool(CONTEXT.search(text)) and bool(ALLOCATION.search(text))


def location(symbol, root):
    where = symbol.get("location", {})
    path = where.get("uri", "")
    if path.startswith("file://"):
        path = path[len("file://"):]
    if root and path.startswith(root.rstrip("/") + "/"):
        path = path[len(root.rstrip("/")) + 1:]
    line = where.get("position", {}).get("line", -1) + 1
    return path, line


# ---------------------------------------------------------------------------------------------
# The symbol graphs
# ---------------------------------------------------------------------------------------------

def load_graphs(directory, modules):
    """[(module, extended module or None, graph)] for the graphs of the named modules."""
    if not os.path.isdir(directory):
        raise Refused("there is no folder %s" % directory)
    out = []
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".symbols.json"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            graph = json.load(handle)
        module = graph["module"]["name"]
        if modules and module not in modules:
            continue
        match = re.match(r"^[^@]+@(.+)\.symbols\.json$", name)
        out.append((module, match.group(1) if match else None, graph))
    if not out:
        raise Refused("%s holds no symbol graph%s" % (directory, " of " + ", ".join(sorted(modules)) if modules else ""))
    return out


def audit_graphs(graphs, root):
    """(findings, per-module counts) for checks [no comment] and [no contract]."""
    counts = collections.defaultdict(lambda: {"symbols": 0, "comment": 0, "contract": 0, "synthesized": 0})
    symbols, module_of, foreign = {}, {}, set()
    member_of, requirements, conformances = {}, collections.defaultdict(dict), collections.defaultdict(set)
    implements, requirement_of = {}, {}
    for module, extended, graph in graphs:
        counts[module]          # a module whose graph is empty (the facade) is still counted
        for symbol in graph.get("symbols", []):
            usr = symbol["identifier"]["precise"]
            symbols[usr] = symbol
            module_of[usr] = module
            if extended:
                foreign.add(usr)
        for relationship in graph.get("relationships", []):
            kind = relationship["kind"]
            if kind == "memberOf":
                member_of[relationship["source"]] = relationship["target"]
            elif kind in ("requirementOf", "optionalRequirementOf"):
                requirements[relationship["target"]][relationship["source"]] = True
                requirement_of[relationship["source"]] = relationship["target"]
            elif kind in ("conformsTo", "inheritsFrom"):
                conformances[relationship["source"]].add(relationship["target"])
            elif kind == "defaultImplementationOf":
                implements[relationship["source"]] = relationship["target"]

    def protocols_of(usr):
        seen, todo = set(), list(conformances.get(usr, ()))
        while todo:
            protocol = todo.pop()
            if protocol in seen:
                continue
            seen.add(protocol)
            todo.extend(conformances.get(protocol, ()))
        return seen

    def requirement_states_contract(requirement):
        if requirement not in symbols:
            return False
        if states_contract(comment_text(symbols[requirement])):
            return True
        protocol = requirement_of.get(requirement) or member_of.get(requirement)
        return protocol in symbols and states_contract(comment_text(symbols[protocol]))

    def witnesses_a_stated_requirement(usr):
        """A member of another module's type that implements a requirement stating its contract."""
        if usr in implements and requirement_states_contract(implements[usr]):
            return True
        name = symbols[usr]["pathComponents"][-1]
        owner = member_of.get(usr)
        if owner is None:
            return False
        for protocol in protocols_of(owner) | ({owner} if owner in requirements else set()):
            for requirement in requirements.get(protocol, {}):
                if requirement in symbols and symbols[requirement]["pathComponents"][-1] == name and requirement_states_contract(requirement):
                    return True
        return False

    findings = []
    for usr, symbol in symbols.items():
        module = module_of[usr]
        kind = symbol["kind"]["identifier"]
        path, line = location(symbol, root)
        name = ".".join(symbol["pathComponents"])
        counts[module]["symbols"] += 1
        if not symbol.get("location"):
            # Written by the compiler (`init(rawValue:)` of a raw-valued enumeration, `init(from:)`
            # of a Decodable type): there is no declaration to comment, and the symbol implements
            # a requirement of the standard library, whose contract it has (CR-033).
            counts[module]["synthesized"] += 1
            continue
        text = comment_text(symbol)
        doc = symbol.get("docComment") or {}
        own = bool(text)
        if own and doc.get("uri") and symbol.get("location", {}).get("uri") and doc["uri"] != symbol["location"]["uri"]:
            own = False     # a comment of another file: inherited, which -skip-inherited-docs should have dropped
        label = KIND_NAMES.get(kind, kind)
        if not own:
            counts[module]["comment"] += 1
            findings.append((path, line, "no comment", "%s %s: no documentation comment of its own (VIS-2)" % (label, name)))
            continue
        needs_contract = kind in TYPE_KINDS
        if kind in GLOBAL_FUNCTION_KINDS and usr not in member_of:
            needs_contract = True
        if usr in foreign and kind not in TYPE_KINDS and not witnesses_a_stated_requirement(usr):
            needs_contract = True
        if needs_contract:
            missing = []
            if not CONTEXT.search(text):
                missing.append("the context that may call it")
            if not ALLOCATION.search(text):
                missing.append("whether it allocates")
            if missing:
                counts[module]["contract"] += 1
                why = "a member %s adds to a type of another module" % module if usr in foreign and kind not in TYPE_KINDS else label
                findings.append((path, line, "no contract", "%s %s: its comment does not say %s (VIS-2; %s)" % (
                    label, name, " or ".join(missing), why)))
    return findings, counts


# ---------------------------------------------------------------------------------------------
# The sources
# ---------------------------------------------------------------------------------------------

def strip_attributes(text, depth):
    """(rest of the line after leading attributes, paren depth still open, unavailable seen)."""
    unavailable = False
    index = 0
    if depth > 0:
        index, depth = skip_balanced(text, 0, depth)
        if depth > 0:
            return "", depth, unavailable
    while True:
        while index < len(text) and text[index] in " \t":
            index += 1
        if index < len(text) and text[index] == "@":
            match = re.match(r"@[A-Za-z_][\w.]*", text[index:])
            if not match:
                break
            start = index
            index += match.end()
            if index < len(text) and text[index] == "(":
                index, depth = skip_balanced(text, index, 0)
                if re.search(r"^@available\s*\(\s*\*\s*,\s*unavailable", text[start:index]):
                    unavailable = True
                if depth > 0:
                    if re.search(r"^@available\s*\(\s*\*\s*,\s*unavailable", text[start:]):
                        unavailable = True
                    return "", depth, unavailable
            continue
        break
    return text[index:], depth, unavailable


def skip_balanced(text, index, depth):
    """Scans parentheses from `index`, honouring string literals; returns (index after, depth)."""
    in_string = False
    while index < len(text):
        char = text[index]
        if in_string:
            if char == "\\":
                index += 2
                continue
            if char == '"':
                in_string = False
        elif char == '"':
            in_string = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index + 1, 0
        index += 1
    return index, depth


def audit_sources(folder, root):
    """(findings, declarations seen) for check [source]."""
    findings, seen = [], 0
    for directory, names, files in os.walk(folder):
        names.sort()
        for name in sorted(files):
            if not name.endswith(".swift"):
                continue
            path = os.path.join(directory, name)
            shown = os.path.relpath(path, root) if root else path
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
            doc, attributes_unavailable, depth = None, False, 0
            for number, raw in enumerate(lines, 1):
                stripped = raw.strip()
                if stripped.startswith("///"):
                    doc = (doc or []) + [stripped[3:].strip()]
                    attributes_unavailable = False
                    continue
                if depth == 0 and re.match(r"#(if|elseif|else|endif)\b", stripped):
                    continue            # a conditional around attributes: the comment above it holds
                if depth > 0 or stripped.startswith("@"):
                    rest, depth, unavailable = strip_attributes(stripped, depth)
                    attributes_unavailable = attributes_unavailable or unavailable
                    if depth > 0 or not rest.strip():
                        continue        # an attribute line: the comment above still stands
                    stripped = rest.strip()
                match = DECLARATION.match(stripped)
                if match and match.group(1) != "extension":
                    seen += 1
                    text = " ".join(doc or [])
                    declaration = stripped[:100]
                    if not doc:
                        findings.append((shown, number, "source", "`%s`: no `///` comment directly above it (VIS-2)" % declaration))
                    elif attributes_unavailable and not DIAGNOSTIC.search(text):
                        findings.append((shown, number, "source", "`%s`: an unavailable declaration whose comment does not say that "
                                         "it exists for its diagnostic (ORD-4, CR-033)" % declaration))
                doc, attributes_unavailable = None, False
    return findings, seen


# ---------------------------------------------------------------------------------------------
# The C headers
# ---------------------------------------------------------------------------------------------

def audit_headers(folder, root):
    """(findings, declarations seen) for check [C]."""
    findings, seen = [], 0
    for name in sorted(os.listdir(folder)):
        if not name.endswith(".h"):
            continue
        path = os.path.join(folder, name)
        shown = os.path.relpath(path, root) if root else path
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().split("\n")
        for number, name_found, kind in header_declarations(lines):
            seen += 1
            if not header_documented(lines, number):
                findings.append((shown, number, "C", "%s %s: no comment above it, above its group or on its line (VIS-2)" % (kind, name_found)))
    return findings, seen


def header_declarations(lines):
    """[(line number, name, kind)] of the top-level declarations of a header."""
    out, depth, in_comment, statement, start, guard = [], 0, False, "", None, None
    for number, raw in enumerate(lines, 1):
        line = raw
        # Drop comments, keeping track of /* … */ that span lines.
        code = ""
        index = 0
        while index < len(line):
            if in_comment:
                end = line.find("*/", index)
                if end < 0:
                    index = len(line)
                    break
                in_comment = False
                index = end + 2
                continue
            if line.startswith("/*", index):
                in_comment = True
                index += 2
                continue
            if line.startswith("//", index):
                break
            code += line[index]
            index += 1
        text = code.strip()
        if not text and not statement:
            continue
        if text.startswith("#"):
            match = re.match(r"#\s*ifndef\s+(\w+)", text)
            if match:
                guard = match.group(1)
            match = re.match(r"#\s*define\s+(\w+)", text)
            if match and match.group(1) != guard and depth == 0:
                out.append((number, match.group(1), "macro"))
            continue
        if depth == 0 and not statement:
            if text in ("}",) or text.startswith('extern "C"'):
                continue
            start = number
        statement += " " + text
        depth += text.count("{") - text.count("}")
        if depth == 0 and statement.rstrip().endswith(";"):
            declaration = re.sub(r"\s+", " ", statement).strip()
            statement = ""
            body_free = re.sub(r"\{.*\}", "{}", declaration)
            if body_free.startswith("typedef"):
                names = re.findall(r"(\w+)\s*(?:\)\s*\([^)]*\))?\s*;$", body_free) or re.findall(r"\(\s*\*\s*(\w+)\s*\)", body_free)
                tag = re.match(r"typedef\s+(?:struct|enum|union)\s+(\w+)", body_free)
                out.append((start, names[-1] if names else (tag.group(1) if tag else "?"), "type"))
            elif re.match(r"(struct|enum|union)\s+\w+\s*\{", body_free):
                out.append((start, re.match(r"(?:struct|enum|union)\s+(\w+)", body_free).group(1), "type"))
            elif "(" in body_free:
                match = re.search(r"(\w+)\s*\(", body_free)
                out.append((start, match.group(1) if match else "?", "function"))
            else:
                match = re.search(r"(\w+)\s*(?:\[[^\]]*\])?\s*;$", body_free)
                out.append((start, match.group(1) if match else "?", "declaration"))
    return out


def header_documented(lines, number):
    """A comment ends directly above the declaration, or above the run of lines it belongs to,
    or stands on its first line."""
    first = lines[number - 1]
    if "/*" in first or "//" in first:
        return True
    index = number - 2
    while index >= 0:
        text = lines[index].strip()
        if not text or text.startswith("#"):
            return False
        if text.endswith("*/") or text.startswith("//") or text.startswith("/*") or text.startswith("*"):
            return True
        index -= 1      # a declaration of the same group: keep looking up
    return False


# ---------------------------------------------------------------------------------------------
# The documentation catalogs
# ---------------------------------------------------------------------------------------------

SNIPPET_MARKER = re.compile(r"^\s*<!--\s*snippet:\s*(\S+?)#([A-Za-z0-9_-]+)\s*-->\s*$")
SNIPPET_BEGIN = re.compile(r"^\s*//\s*snippet:begin\s+([A-Za-z0-9_-]+)\s*$")
SNIPPET_END = re.compile(r"^\s*//\s*snippet:end\s+([A-Za-z0-9_-]+)\s*$")
FENCE = re.compile(r"^\s*(```+)\s*([A-Za-z0-9_+-]*)")


def snippet_regions(path):
    """({region: [lines, less their common indentation]}, [problems]) of one source file."""
    with open(path, encoding="utf-8") as handle:
        lines = handle.read().split("\n")
    found, problems, name, start = {}, [], None, 0
    for number, text in enumerate(lines, 1):
        begin, end = SNIPPET_BEGIN.match(text), SNIPPET_END.match(text)
        if begin:
            if name is not None:
                problems.append((number, "the region %s begins inside the region %s" % (begin.group(1), name)))
            name, start = begin.group(1), number
        elif end:
            if end.group(1) != name:
                problems.append((number, "`snippet:end %s` closes no region of that name" % end.group(1)))
            else:
                if name in found:
                    problems.append((number, "the region %s is marked twice" % name))
                body = lines[start:number - 1]
                indents = [len(line) - len(line.lstrip()) for line in body if line.strip()]
                cut = min(indents) if indents else 0
                found[name] = [line[cut:].rstrip() if line.strip() else "" for line in body]
            name = None
    if name is not None:
        problems.append((start, "the region %s never ends" % name))
    return found, problems


def audit_catalogs(folder, root):
    """(findings, examples seen) for check [example]."""
    findings, seen, cache = [], 0, {}
    for directory, names, files in os.walk(folder):
        names.sort()
        if not any(part.endswith(".docc") for part in directory.replace(os.sep, "/").split("/")):
            continue            # an article lives in a catalog; other Markdown is not DocC's
        for name in sorted(files):
            if not name.endswith(".md"):
                continue
            path = os.path.join(directory, name)
            shown = os.path.relpath(path, root) if root else path
            with open(path, encoding="utf-8") as handle:
                lines = handle.read().split("\n")
            marker, number = None, 0
            while number < len(lines):
                text = lines[number]
                number += 1
                match = SNIPPET_MARKER.match(text)
                if match:
                    if marker:
                        findings.append((shown, marker[0], "example", "the marker of %s#%s is not followed by a code block" % marker[1:]))
                    marker = (number, match.group(1), match.group(2))
                    continue
                fence = FENCE.match(text)
                if fence:
                    opened, language, body = number, fence.group(2), []
                    while number < len(lines) and not lines[number].strip().startswith(fence.group(1)):
                        body.append(lines[number].rstrip())
                        number += 1
                    number += 1     # the closing fence
                    if marker is None:
                        if language in ("swift", ""):
                            findings.append((shown, opened, "example", "a %s block that no compiled region backs: put a "
                                             "`<!-- snippet: <file>#<region> -->` line before it" % (language or "code")))
                        continue
                    seen += 1
                    _, source, region = marker
                    marker = None
                    source_path = os.path.join(root or ".", source)
                    if not os.path.isfile(source_path):
                        findings.append((shown, opened, "example", "the marker names %s, which does not exist" % source))
                        continue
                    if source_path not in cache:
                        cache[source_path] = snippet_regions(source_path)
                        for line, problem in cache[source_path][1]:
                            findings.append((source, line, "example", problem))
                    regions = cache[source_path][0]
                    if region not in regions:
                        findings.append((shown, opened, "example", "%s marks no region %s" % (source, region)))
                    elif body != regions[region]:
                        difference = [line for line in difflib.unified_diff(regions[region], body, source + "#" + region, shown, lineterm="", n=0)
                                      if not line.startswith("@@")]
                        findings.append((shown, opened, "example", "the block is not the code of %s#%s:\n        %s" % (
                            source, region, "\n        ".join(difference[:12]))))
                    continue
                if marker and text.strip():
                    findings.append((shown, marker[0], "example", "the marker of %s#%s is not followed by a code block" % marker[1:]))
                    marker = None
            if marker:
                findings.append((shown, marker[0], "example", "the marker of %s#%s is not followed by a code block" % marker[1:]))
    return findings, seen


# ---------------------------------------------------------------------------------------------
# The documentation build
# ---------------------------------------------------------------------------------------------

WARNING = re.compile(r"^(?P<path>/[^:]+):(?P<line>\d+):(?P<column>\d+): warning: (?P<message>.*?)"
                     r"(?: \(in target '[^']*' from project '[^']*'\))?\s*$")


def docbuild(log, archives, root, status):
    """Prints the warnings of the package and the pages per archive; returns the exit status."""
    if not os.path.isfile(log):
        raise Refused("there is no log at %s" % log)
    with open(log, encoding="utf-8", errors="replace") as handle:
        lines = handle.read().split("\n")
    package = (root or "").rstrip("/") + "/"
    ours, others, errors = [], [], []
    for text in lines:
        match = WARNING.match(text)
        if match:
            path = match.group("path")
            if root and path.startswith(package):
                entry = "%s:%s:%s: warning: %s" % (path[len(package):], match.group("line"), match.group("column"), match.group("message"))
                if entry not in ours:
                    ours.append(entry)
                continue
        if " warning: " in text or text.startswith("warning: "):
            entry = text.strip()
            if entry not in others:
                others.append(entry)
        elif " error: " in text or text.startswith("error: "):
            entry = text.strip()
            if entry not in errors:
                errors.append(entry)
    for entry in ours:
        print("docs: %s" % entry)
    for entry in others:
        print("docs: note, not of the package: %s" % entry)
    pages = {}
    if os.path.isdir(archives):
        for name in sorted(os.listdir(archives)):
            if name.endswith(".doccarchive"):
                count = 0
                for directory, _, files in os.walk(os.path.join(archives, name, "data", "documentation")):
                    count += sum(1 for file in files if file.endswith(".json"))
                pages[name[:-len(".doccarchive")]] = count
    for module in sorted(pages):
        print("docs: %s: %d page%s" % (module, pages[module], "" if pages[module] == 1 else "s"))
    failed = False
    if status != 0:
        for entry in errors[:20]:
            print("docs: %s" % entry)
        print("docs: the documentation build failed (xcodebuild exit %d)" % status)
        failed = True
    if not pages:
        print("docs: the build made no documentation archive under %s" % archives)
        failed = True
    if ours:
        print("docs: %d warning%s for the package's sources" % (len(ours), "" if len(ours) == 1 else "s"))
        failed = True
    if failed:
        return 1
    print("docs: %d archives, %d pages, no warning for the package's sources" % (len(pages), sum(pages.values())))
    return 0


LINK_REFERENCE = re.compile(r'"type"\s*:\s*"link"')


def links(archive, root):
    """Prints each link to a path under /documentation/ that names no page of the combined
    archive; returns the exit status."""
    data = os.path.join(archive, "data")
    if not os.path.isdir(os.path.join(data, "documentation")):
        raise Refused("there is no documentation archive at %s" % archive)
    shown = archive
    if root:
        relative = os.path.relpath(os.path.abspath(archive), os.path.abspath(root))
        shown = archive if relative.startswith("..") else relative
    pages, checked, broken = 0, 0, []
    for directory, _, files in os.walk(os.path.join(data, "documentation")):
        for file in sorted(files):
            if not file.endswith(".json"):
                continue
            path = os.path.join(directory, file)
            pages += 1
            with open(path, encoding="utf-8") as handle:
                text = handle.read()
            if not LINK_REFERENCE.search(text):
                continue
            page = "/" + os.path.relpath(path, data)[:-len(".json")]
            for reference in json.loads(text).get("references", {}).values():
                url = reference.get("url", "") if isinstance(reference, dict) else ""
                if not url.startswith("/documentation/") or reference.get("type") != "link":
                    continue
                checked += 1
                target = url.split("#", 1)[0].rstrip("/").lower()
                if not os.path.isfile(os.path.join(data, target.lstrip("/") + ".json")) and (page, url) not in broken:
                    broken.append((page, url))
    for page, url in sorted(broken):
        print("docs: %s links to %s, which is no page of %s" % (page, url, shown))
    if broken:
        print("docs: %d link%s to no page" % (len(broken), "" if len(broken) == 1 else "s"))
        return 1
    print("docs: %s: %d pages; %d link%s written as a path, each to a page of the archive"
          % (shown, pages, checked, "" if checked == 1 else "s"))
    return 0


# ---------------------------------------------------------------------------------------------

def main(arguments):
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if arguments else 2
    if arguments[0] == "docbuild":
        return main_docbuild(arguments[1:])
    if arguments[0] == "links":
        return main_links(arguments[1:])
    if arguments[0] != "audit":
        print("docs: there is no command %s" % arguments[0], file=sys.stderr)
        return 2
    graphs_dir, sources, headers, catalogs, modules, report, root = None, [], [], [], set(), None, None
    rest = list(arguments[1:])
    try:
        while rest:
            option = rest.pop(0)
            if option in ("--graphs", "--sources", "--headers", "--catalogs", "--module", "--report", "--root") and rest:
                value = rest.pop(0)
                if option == "--graphs":
                    graphs_dir = value
                elif option == "--sources":
                    sources.append(value)
                elif option == "--headers":
                    headers.append(value)
                elif option == "--catalogs":
                    catalogs.append(value)
                elif option == "--module":
                    modules.add(value)
                elif option == "--report":
                    report = value
                else:
                    root = value
            else:
                raise Refused("unknown argument %s" % option)
        if not graphs_dir and not sources and not headers and not catalogs:
            raise Refused("audit needs --graphs, --sources, --headers or --catalogs")
        findings, counts, declarations, c_declarations, examples = [], {}, 0, 0, 0
        if graphs_dir:
            graph_findings, counts = audit_graphs(load_graphs(graphs_dir, modules), root)
            findings += graph_findings
        for folder in sources:
            if not os.path.isdir(folder):
                raise Refused("there is no folder %s" % folder)
            found, seen = audit_sources(folder, root)
            findings += found
            declarations += seen
        for folder in headers:
            if not os.path.isdir(folder):
                raise Refused("there is no folder %s" % folder)
            found, seen = audit_headers(folder, root)
            findings += found
            c_declarations += seen
        for folder in catalogs:
            if not os.path.isdir(folder):
                raise Refused("there is no folder %s" % folder)
            found, seen = audit_catalogs(folder, root)
            findings += found
            examples += seen
    except Refused as refusal:
        print("docs: %s" % refusal, file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError) as error:
        print("docs: cannot read the input: %s" % error, file=sys.stderr)
        return 2

    findings.sort()
    lines = ["%s:%d: [%s] %s" % finding for finding in findings]
    if report:
        os.makedirs(os.path.dirname(os.path.abspath(report)), exist_ok=True)
        with open(report, "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + ("\n" if lines else ""))
    for line in lines:
        print("docs: " + line)
    for module in sorted(counts):
        count = counts[module]
        print("docs: %s: %d public symbols, %d without a comment of their own, %d without a contract%s" % (
            module, count["symbols"], count["comment"], count["contract"],
            ", %d written by the compiler" % count["synthesized"] if count["synthesized"] else ""))
    if sources:
        print("docs: sources: %d public declarations, %d without a comment directly above" % (
            declarations, sum(1 for finding in findings if finding[2] == "source")))
    if headers:
        print("docs: C headers: %d declarations, %d without a comment" % (c_declarations, sum(1 for finding in findings if finding[2] == "C")))
    if catalogs:
        print("docs: catalogs: %d examples, %d findings" % (examples, sum(1 for finding in findings if finding[2] == "example")))
    if findings:
        print("docs: %d finding%s (VIS-2)" % (len(findings), "" if len(findings) == 1 else "s"))
        return 1
    print("docs: every public symbol is documented with its threading contract (VIS-2)")
    return 0


def main_docbuild(arguments):
    log, archives, root, status = None, None, None, 0
    rest = list(arguments)
    try:
        while rest:
            option = rest.pop(0)
            if option in ("--log", "--archives", "--root", "--status") and rest:
                value = rest.pop(0)
                if option == "--log":
                    log = value
                elif option == "--archives":
                    archives = value
                elif option == "--root":
                    root = value
                else:
                    status = int(value)
            else:
                raise Refused("unknown argument %s" % option)
        if not log or not archives:
            raise Refused("docbuild needs --log and --archives")
        return docbuild(log, archives, root, status)
    except Refused as refusal:
        print("docs: %s" % refusal, file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print("docs: cannot read the input: %s" % error, file=sys.stderr)
        return 2


def main_links(arguments):
    archive, root = None, None
    rest = list(arguments)
    try:
        while rest:
            option = rest.pop(0)
            if option in ("--archive", "--root") and rest:
                value = rest.pop(0)
                if option == "--archive":
                    archive = value
                else:
                    root = value
            else:
                raise Refused("unknown argument %s" % option)
        if not archive:
            raise Refused("links needs --archive")
        return links(archive, root)
    except Refused as refusal:
        print("docs: %s" % refusal, file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print("docs: cannot read the input: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
