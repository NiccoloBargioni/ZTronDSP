#!/usr/bin/env python3
"""The extension guide, generated (WP-908): Docs/ExtensionGuide.md from its template and from the
marked regions of the external package.

    python3 Scripts/lib/extension_guide.py            writes the guide from the template
    python3 Scripts/lib/extension_guide.py --check    exit 1 when the guide is not what the
                                                      template makes (nothing is written)
    options: --root <package>  --tree <external package>  --template <file>  --guide <file>

The template is the guide without its code. Where the guide shows code of a compiled file, the
template has the marker alone, on a line of its own:

    <!-- snippet: ExternalParity/<path in the external package>#<region> -->

and the generator puts after it a fenced block, in the language of the file, that holds the
region's lines as they are. A region is marked in its file by a line `// snippet:begin <region>`
before it and a line `// snippet:end <region>` after it (in C, `/* snippet:begin <region> */`).
Everything else of the template is copied as it is.

Refused, with the line named: a marker whose file or region does not exist, a marker that is
followed by a fenced block in the template (the template holds no copy of the code), a region
that is marked twice, begins inside another or never ends. `Scripts/external-parity.sh --step
guide` runs the check, so the guide cannot drift from the sources or from its template.

Exit status: 0 written, or equal; 1 the guide differs, or a problem; 2 usage error.
"""
import argparse
import difflib
import os
import re
import sys

PREFIX = "ExternalParity/"
LANGUAGE = {".swift": "swift", ".c": "c", ".h": "c"}
SKIPPED = {".build", ".swiftpm", ".git", "DerivedData", "Docs", "__pycache__"}
BEGIN = re.compile(r"^\s*(?://|/\*)\s*snippet:begin\s+([A-Za-z0-9_-]+)\s*(?:\*/)?\s*$")
END = re.compile(r"^\s*(?://|/\*)\s*snippet:end\s+([A-Za-z0-9_-]+)\s*(?:\*/)?\s*$")
MARKER = re.compile(r"^<!--\s*snippet:\s*(\S+?)#([A-Za-z0-9_-]+)\s*-->\s*$")
FENCE = re.compile(r"^```")


def regions(tree):
    """{(path as the guide names it, region): [lines]} of every marked region under `tree`, and
    the problems met on the way."""
    found, problems = {}, []
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
                    if (relative, name) in found:
                        problems.append("%s:%d: the region %s is marked twice" % (relative, number, name))
                elif end:
                    if name != end.group(1):
                        problems.append("%s:%d: the region %s ends, and %s was open" % (relative, number, end.group(1), name or "none"))
                    else:
                        found[(relative, name)] = source[start:number - 1]
                    name = None
            if name is not None:
                problems.append("%s:%d: the region %s never ends" % (relative, start, name))
    return found, problems


def generate(template_lines, tree, template_name):
    """The guide the template makes, as a list of lines, and the problems that prevent it."""
    found, problems = regions(tree)
    out = []
    for number, text in enumerate(template_lines, start=1):
        out.append(text)
        marker = MARKER.match(text)
        if not marker:
            continue
        path, name = marker.group(1), marker.group(2)
        following = template_lines[number] if number < len(template_lines) else ""
        if FENCE.match(following):
            problems.append("%s:%d: the marker %s#%s is followed by a fenced block: the template holds the marker alone, and the generator puts the code after it"
                            % (template_name, number, path, name))
            continue
        if not path.startswith(PREFIX) or ".." in path.split("/"):
            problems.append("%s:%d: the marker %s#%s: a path begins with %s, the package whose files are compiled and tested" % (template_name, number, path, name, PREFIX))
            continue
        language = LANGUAGE.get(os.path.splitext(path)[1])
        if language is None:
            problems.append("%s:%d: the marker %s#%s names a file that is neither Swift nor C" % (template_name, number, path, name))
            continue
        if (path, name) not in found:
            there = os.path.isfile(os.path.join(tree, path[len(PREFIX):]))
            problems.append("%s:%d: the marker %s#%s: %s" % (template_name, number, path, name,
                                                            "that file marks no region of this name" if there else "there is no such file"))
            continue
        out.append("```" + language)
        out.extend(found[(path, name)])
        out.append("```")
    return out, problems


def main(argv):
    parser = argparse.ArgumentParser(prog="extension_guide.py", description="Writes or checks Docs/ExtensionGuide.md from its template.")
    parser.add_argument("--root", default=os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")))
    parser.add_argument("--tree", help="the external package (default <root>/ExternalParity)")
    parser.add_argument("--template", help="the template (default <root>/Docs/ExtensionGuide.template.md)")
    parser.add_argument("--guide", help="the guide (default <root>/Docs/ExtensionGuide.md)")
    parser.add_argument("--check", action="store_true", help="compare instead of writing")
    try:
        arguments = parser.parse_args(argv)
    except SystemExit as exit:
        return 2 if exit.code else 0
    tree = arguments.tree or os.path.join(arguments.root, "ExternalParity")
    template = arguments.template or os.path.join(arguments.root, "Docs", "ExtensionGuide.template.md")
    guide = arguments.guide or os.path.join(arguments.root, "Docs", "ExtensionGuide.md")
    if not os.path.isfile(os.path.join(tree, "Package.swift")):
        print("extension-guide: there is no external package at %s" % tree)
        return 2
    if not os.path.isfile(template):
        print("extension-guide: there is no template at %s: the guide is generated from it" % template)
        return 1
    with open(template, encoding="utf-8") as handle:
        template_lines = handle.read().split("\n")
    lines, problems = generate(template_lines, tree, os.path.basename(template))
    for problem in problems:
        print("extension-guide: %s" % problem)
    if problems:
        print("extension-guide: %d problem%s; nothing was %s" % (len(problems), "" if len(problems) == 1 else "s", "compared" if arguments.check else "written"))
        return 1
    text = "\n".join(lines)
    if arguments.check:
        current = open(guide, encoding="utf-8").read() if os.path.isfile(guide) else None
        if current == text:
            print("extension-guide: %s is what its template makes (%d blocks of compiled code)" % (os.path.basename(guide), sum(1 for line in template_lines if MARKER.match(line))))
            return 0
        if current is None:
            print("extension-guide: there is no guide at %s" % guide)
            return 1
        print("extension-guide: %s is not what its template makes: edit %s and run python3 Scripts/lib/extension_guide.py" % (guide, template))
        diff = list(difflib.unified_diff(current.split("\n"), lines, "the guide", "what the template makes", n=1, lineterm=""))
        for line in diff[:40]:
            print("    | " + line)
        if len(diff) > 40:
            print("    | … %d lines more" % (len(diff) - 40))
        return 1
    with open(guide, "w", encoding="utf-8") as handle:
        handle.write(text)
    print("extension-guide: wrote %s from %s" % (guide, template))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
