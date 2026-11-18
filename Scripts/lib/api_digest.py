"""Turns symbol graphs into the committed API digest and checks the rules over it (WP-013, VIS-3).

    api_digest.py render  --graphs DIR --out DIR [--module NAME]… [--reexports NAME=FILE,…]
    api_digest.py compare --fresh DIR --committed DIR
    api_digest.py rules   --graphs DIR [--exemptions FILE]

`render` writes one text file per module, `<Module>.txt`: one line per public symbol, sorted,
with its kind, its path, its declaration (default values and `where` clauses included), its
availability, and one line per conformance. Documentation comments are not part of it.

`compare` fails on any difference between two digest folders, in either direction.

`rules` checks, over the graphs of all modules together, that every public initialiser of a
type that conforms to PipelineStage or SequenceStage takes `isActive:` as its last argument, or
as its last argument before trailing closures (API-5, ACT-1). Types named in the exemptions
file have nothing to switch.

Exit status: 0 ok, 1 differences or rule violations, 2 usage error.
"""

import difflib
import json
import os
import re
import subprocess
import sys

STAGE_PROTOCOLS = ("PipelineStage", "SequenceStage")
IMPLICIT_CONFORMANCES = ("Swift.Copyable", "Swift.Escapable", "Swift.BitwiseCopyable")


def load_graphs(directory):
    """{module name: [graph, …]} for every *.symbols.json under `directory`."""
    graphs = {}
    for name in sorted(os.listdir(directory)):
        if not name.endswith(".symbols.json"):
            continue
        with open(os.path.join(directory, name), encoding="utf-8") as handle:
            graph = json.load(handle)
        graph["_file"] = name
        graphs.setdefault(graph["module"]["name"], []).append(graph)
    return graphs


def declaration(symbol):
    text = "".join(fragment["spelling"] for fragment in symbol.get("declarationFragments", []))
    return re.sub(r"\s+", " ", text).strip()


def version(value):
    if not value:
        return ""
    parts = [str(value.get("major", 0)), str(value.get("minor", 0))]
    if value.get("patch"):
        parts.append(str(value["patch"]))
    return ".".join(parts)


def availability(symbol):
    out = []
    for item in symbol.get("availability", []):
        domain = item.get("domain", "*")
        pieces = [domain]
        if item.get("isUnconditionallyUnavailable"):
            pieces.append("unavailable")
        if item.get("isUnconditionallyDeprecated"):
            pieces.append("deprecated")
        for key in ("introduced", "deprecated", "obsoleted"):
            if item.get(key):
                pieces.append("%s: %s" % (key, version(item[key])))
        if item.get("renamed"):
            pieces.append("renamed: %s" % json.dumps(item["renamed"], ensure_ascii=False))
        if item.get("message"):
            pieces.append("message: %s" % json.dumps(item["message"], ensure_ascii=False))
        out.append("@available(%s)" % ", ".join(pieces))
    return sorted(out)


_READABLE = {}


def readable(usr):
    """`Swift.Bool` for `s:Sb`. A USR that cannot be demangled is returned as it is."""
    if usr not in _READABLE:
        name = usr
        if usr.startswith("s:"):
            try:
                result = subprocess.run(["xcrun", "swift-demangle", "-compact", "$s" + usr[2:]], capture_output=True, text=True, timeout=30)
                candidate = result.stdout.strip()
                if result.returncode == 0 and candidate and not candidate.startswith("$s"):
                    name = candidate
            except (OSError, subprocess.SubprocessError):
                pass
        _READABLE[usr] = name
    return _READABLE[usr]


def render_module(module, graphs, reexports):
    names = {}
    for graph in graphs:
        for symbol in graph.get("symbols", []):
            names[symbol["identifier"]["precise"]] = ".".join(symbol["pathComponents"])

    lines = set()
    for graph in graphs:
        extended = None
        match = re.match(r"^.+@(.+)\.symbols\.json$", graph["_file"])
        if match:
            extended = match.group(1)
        for symbol in graph.get("symbols", []):
            line = "%-22s %s : %s" % (symbol["kind"]["identifier"], ".".join(symbol["pathComponents"]), declaration(symbol))
            for item in availability(symbol):
                line += " " + item
            if extended:
                line += "   [extends %s]" % extended
            lines.add(line)
        for relationship in graph.get("relationships", []):
            if relationship["kind"] not in ("conformsTo", "inheritsFrom"):
                continue
            target = relationship.get("targetFallback") or names.get(relationship["target"]) or relationship["target"]
            if target in IMPLICIT_CONFORMANCES:
                continue
            # A conformance this module adds to a type of another module has no name here: its
            # Swift USR is the type's mangled name, which the demangler turns into `Module.Type`.
            source = names.get(relationship["source"]) or relationship.get("sourceFallback") or readable(relationship["source"])
            lines.add("%-22s %s : %s" % ("conformance" if relationship["kind"] == "conformsTo" else "inheritance", source, target))
    for name in sorted(reexports):
        lines.add("%-22s %s" % ("reexport", name))

    header = [
        "# %s — public API digest (VIS-3)." % module,
        "# Generated from the built module by Scripts/api-digest.sh --update. Do not edit: a difference",
        "# from the build fails CI gate 4, and changing the public API is a change request.",
        "",
    ]
    return "\n".join(header + sorted(lines)) + "\n"


def command_render(arguments):
    graphs_directory, out, modules, reexports = None, None, [], {}
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument in ("--graphs", "--out", "--module", "--reexports") and index + 1 < len(arguments):
            index += 1
            value = arguments[index]
            if argument == "--graphs":
                graphs_directory = value
            elif argument == "--out":
                out = value
            elif argument == "--module":
                modules.append(value)
            else:
                for pair in [p for p in value.split(",") if p]:
                    name, _, path = pair.partition("=")
                    reexports[name] = path
        else:
            print("api-digest: unknown argument %s" % argument, file=sys.stderr)
            return 2
        index += 1
    if not graphs_directory or not out:
        print("api-digest: render needs --graphs and --out", file=sys.stderr)
        return 2
    graphs = load_graphs(graphs_directory)
    os.makedirs(out, exist_ok=True)
    for module in modules or sorted(graphs):
        exported = set()
        if module in reexports and os.path.isdir(reexports[module]):
            for folder, _, files in os.walk(reexports[module]):
                for name in files:
                    if name.endswith(".swift"):
                        with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as handle:
                            exported.update(re.findall(r"^[ \t]*@_exported[ \t]+import[ \t]+(?:(?:struct|class|enum|protocol|typealias|func|var|let)[ \t]+)?([A-Za-z_][\w.]*)", handle.read(), re.MULTILINE))
        text = render_module(module, graphs.get(module, []), exported)
        with open(os.path.join(out, module + ".txt"), "w", encoding="utf-8") as handle:
            handle.write(text)
    return 0


def command_compare(arguments):
    fresh, committed = None, None
    index = 0
    while index < len(arguments):
        if arguments[index] == "--fresh" and index + 1 < len(arguments):
            index += 1
            fresh = arguments[index]
        elif arguments[index] == "--committed" and index + 1 < len(arguments):
            index += 1
            committed = arguments[index]
        else:
            print("api-digest: unknown argument %s" % arguments[index], file=sys.stderr)
            return 2
        index += 1
    if not fresh or not committed:
        print("api-digest: compare needs --fresh and --committed", file=sys.stderr)
        return 2
    fresh_files = {n for n in os.listdir(fresh) if n.endswith(".txt")}
    committed_files = {n for n in os.listdir(committed) if n.endswith(".txt")} if os.path.isdir(committed) else set()
    differences = 0
    for name in sorted(fresh_files | committed_files):
        module = name[:-4]
        if name not in committed_files:
            print("api-digest: %s has no committed digest (%s); run Scripts/api-digest.sh --update" % (module, os.path.join(committed, name)))
            differences += 1
            continue
        if name not in fresh_files:
            print("api-digest: %s is committed and no such module was built" % os.path.join(committed, name))
            differences += 1
            continue
        with open(os.path.join(committed, name), encoding="utf-8") as handle:
            old = handle.read().split("\n")
        with open(os.path.join(fresh, name), encoding="utf-8") as handle:
            new = handle.read().split("\n")
        if old != new:
            differences += 1
            print("api-digest: the public API of %s differs from its committed digest (- committed, + built):" % module)
            for line in difflib.unified_diff(old, new, lineterm="", n=0):
                if line.startswith(("---", "+++", "@@")):
                    continue
                print("    " + line)
    if differences:
        print("api-digest: %d module%s differ. A change of the public API is a change request (VIS-3); "
              "when it is approved, run Scripts/api-digest.sh --update" % (differences, "" if differences == 1 else "s"))
        return 1
    print("api-digest: %d digests equal the built modules" % len(fresh_files))
    return 0


def is_function_type(parameter):
    text = "".join(fragment["spelling"] for fragment in parameter.get("declarationFragments", []))
    _, _, type_text = text.partition(":")
    return "->" in type_text


def command_rules(arguments):
    graphs_directory, exemptions_path = None, None
    index = 0
    while index < len(arguments):
        if arguments[index] == "--graphs" and index + 1 < len(arguments):
            index += 1
            graphs_directory = arguments[index]
        elif arguments[index] == "--exemptions" and index + 1 < len(arguments):
            index += 1
            exemptions_path = arguments[index]
        else:
            print("api-digest: unknown argument %s" % arguments[index], file=sys.stderr)
            return 2
        index += 1
    if not graphs_directory:
        print("api-digest: rules needs --graphs", file=sys.stderr)
        return 2
    exempt = set()
    if exemptions_path and os.path.isfile(exemptions_path):
        with open(exemptions_path, encoding="utf-8") as handle:
            exempt = {line.split("#", 1)[0].strip() for line in handle if line.split("#", 1)[0].strip()}

    graphs = load_graphs(graphs_directory)
    symbols, module_of = {}, {}
    relationships = []
    for module, group in graphs.items():
        for graph in group:
            for symbol in graph.get("symbols", []):
                symbols[symbol["identifier"]["precise"]] = symbol
                module_of[symbol["identifier"]["precise"]] = module
            relationships.extend(graph.get("relationships", []))

    def protocol_name(relationship):
        target = symbols.get(relationship["target"])
        if target is not None:
            return target["pathComponents"][-1] if target["kind"]["identifier"] == "swift.protocol" else None
        return (relationship.get("targetFallback") or "").split(".")[-1] or None

    # Everything that conforms to a stage protocol, directly or through a protocol that refines one.
    stage_protocols = set()      # USRs of protocols that are, or refine, a stage protocol
    stages = set()
    changed = True
    while changed:
        changed = False
        for relationship in relationships:
            if relationship["kind"] != "conformsTo":
                continue
            name = protocol_name(relationship)
            if name in STAGE_PROTOCOLS or relationship["target"] in stage_protocols:
                source = symbols.get(relationship["source"])
                if source is not None and source["kind"]["identifier"] == "swift.protocol":
                    if relationship["source"] not in stage_protocols:
                        stage_protocols.add(relationship["source"])
                        changed = True
                elif relationship["source"] not in stages:
                    stages.add(relationship["source"])
                    changed = True

    owner = {r["source"]: r for r in relationships if r["kind"] == "memberOf"}
    findings, checked = [], 0
    for usr, symbol in sorted(symbols.items(), key=lambda item: (module_of[item[0]], item[1]["pathComponents"])):
        if symbol["kind"]["identifier"] != "swift.init" or usr not in owner:
            continue
        parent = owner[usr]["target"]
        if parent not in stages:
            continue
        parent_name = ".".join(symbol["pathComponents"][:-1])
        if parent_name in exempt or symbol["pathComponents"][0] in exempt:
            continue
        checked += 1
        parameters = symbol.get("functionSignature", {}).get("parameters", [])
        position = next((i for i, p in enumerate(parameters) if p.get("name") == "isActive"), None)
        ok = position is not None and all(is_function_type(p) for p in parameters[position + 1:])
        if not ok:
            reason = "takes no `isActive:`" if position is None else "takes `isActive:` before `%s:`, which is not a trailing closure" % parameters[position + 1].get("name")
            findings.append("%s: %s %s — every public initialiser of a stage ends in `isActive:` (API-5, ACT-1)" % (
                module_of[usr], ".".join(symbol["pathComponents"]), reason))
    for finding in findings:
        print("api-digest: " + finding)
    if findings:
        print("api-digest: %d stage initialiser%s without a trailing `isActive:`" % (len(findings), "" if len(findings) == 1 else "s"))
        return 1
    print("api-digest: %d public initialiser%s of %d stage type%s end in `isActive:`" % (
        checked, "" if checked == 1 else "s", len(stages), "" if len(stages) == 1 else "s"))
    return 0


def main(arguments):
    if not arguments or arguments[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0 if arguments else 2
    commands = {"render": command_render, "compare": command_compare, "rules": command_rules}
    if arguments[0] not in commands:
        print("api-digest: there is no command %s" % arguments[0], file=sys.stderr)
        return 2
    return commands[arguments[0]](arguments[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
