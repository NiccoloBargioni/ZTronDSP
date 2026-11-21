"""The order matrix (WP-328; ORD-2; CI gate 3 of §10.3): every public stage on every domain.

    order_matrix.py [--check] [--stages FILE] [--domains FILE] [--swift FILE] [--document FILE]
                    [--digests DIR] [--not-in-matrix FILE] [--no-scan] [--imports TEXT]
                    [--prelude FILE] [--template TEXT] [--no-modules] [--jobs N]

Tier 1 of the order rules is the type system: a stage compiles only after a domain it takes.
Tier 2 is the `DomainRule` every stage description carries, which runs for every pipeline,
typed or not. The two must agree (ORD-2). This script asks the compiler: for each stage of
`Tests/OrderMatrix/stages.txt` and each domain of `Tests/OrderMatrix/domains.txt` it type-checks
the stage after a pipeline that ends in the domain, and writes what the compiler said

  - to `Tests/ZTronDSPTests/OrderMatrixGenerated.swift`, where `OrderMatrixTests` holds it
    against what the rules say, cell by cell, in the test run (gate 5);
  - to `Docs/OrderMatrix.md`, for people.

`--check` writes nothing: it fails when the committed files are not what the compiler says
today, when a public stage has no line in the list, or when a line names a stage that does not
exist. A stage package regenerates the matrix (STG-1).

THE PUBLIC STAGES are read from the API digests (`Docs/API`, which CI gate 4 holds equal to the
build): every public type, of any module, whose conformance lines reach `StageValue`, the
protocol every stage, step and recipe adopts, directly or through a protocol that refines it
(`PipelineStage`, `SequenceStage`, `Recipe`, `ContextDependentStep`, …). Each has a line in the
list of stages, or one in `Tests/OrderMatrix/not-in-matrix.txt`, `Type | why it is not in the
matrix` (a generic container that takes its domains from its content, say); a line of either
file that names no public stage fails, and so does a stage that has a line in both.

A line of the stage list is `Type | expression`: the expression makes one stage of that type
with any valid arguments. A second spelling of a stage gets a line of its own, named
`Type: what is different`. A line of the domain list is `name | Swift type`.

Exit status: 0 ok, 1 the matrix is out of date or incomplete, 2 usage error, no build, or a
compiler failure that is not about the cell (a stage expression that does not compile on its own).
"""

import concurrent.futures
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
DEFAULT_DIGESTS = os.path.join("Docs", "API")
ROOT_PROTOCOL = "StageValue"
TYPE_KINDS = ("swift.struct", "swift.class", "swift.enum", "swift.actor")
DEFAULT_IMPORTS = "import ZTronDSP\nimport SwiftUI"
DEFAULT_TEMPLATE = "func cell{cell}(_ upstream: Pipeline<Samples, {domain}>) -> some PipelineContent {{ Pipeline {{ upstream; {stage} }} }}"
PROBE_TEMPLATE = "let probe{cell} = {stage}"


class Refused(Exception):
    pass


def read_list(path, what, allow_empty=False):
    if not os.path.isfile(path):
        raise Refused("there is no %s at %s" % (what, os.path.relpath(path, ROOT)))
    entries = []
    with open(path, encoding="utf-8") as handle:
        for number, raw in enumerate(handle, 1):
            line = raw.split("#", 1)[0].strip() if raw.lstrip().startswith("#") else raw.strip()
            if not line or line.startswith("#"):
                continue
            if "|" not in line:
                raise Refused("%s:%d: a line is `name | text`" % (os.path.relpath(path, ROOT), number))
            name, text = [part.strip() for part in line.split("|", 1)]
            if not name or not text:
                raise Refused("%s:%d: a line is `name | text`" % (os.path.relpath(path, ROOT), number))
            entries.append((name, text))
    if not entries and not allow_empty:
        raise Refused("%s is empty" % os.path.relpath(path, ROOT))
    names = [name for name, _ in entries]
    doubles = sorted({name for name in names if names.count(name) > 1})
    if doubles and what == "list of domains":
        raise Refused("%s names %s twice" % (os.path.relpath(path, ROOT), ", ".join(doubles)))
    return entries


def public_stages(folder):
    """{type name: module} of the public types whose conformance lines in the digests under
    `folder` reach StageValue, directly or through the protocols that refine it."""
    base = folder if os.path.isabs(folder) else os.path.join(ROOT, folder)
    if not os.path.isdir(base):
        raise Refused("there is no folder of digests at %s" % os.path.relpath(base, ROOT))
    files = sorted(name for name in os.listdir(base) if name.endswith(".txt"))
    if not files:
        raise Refused("%s holds no digest" % os.path.relpath(base, ROOT))
    modules = {name[:-len(".txt")] for name in files}

    def plain(name):
        # A digest names a type of another module with that module's name in front:
        # `ZTronDSPCore.StageValue`, `ZTronDSPDesign.Decimate`.
        first, _, rest = name.partition(".")
        return rest if rest and (first in modules or first in ("Swift", "SwiftUI", "SwiftUICore", "Foundation")) else name

    declared, protocols, edges = {}, set(), {}
    for name in files:
        module = name[:-len(".txt")]
        with open(os.path.join(base, name), encoding="utf-8") as handle:
            for raw in handle:
                kind, _, rest = raw.strip().partition(" ")
                rest = rest.strip()
                if kind in ("conformance", "inheritance"):
                    source, _, target = rest.partition(" : ")
                    edges.setdefault(plain(source.strip()), set()).add(plain(target.strip()))
                elif kind in TYPE_KINDS:
                    declared[rest.split(" : ", 1)[0].strip()] = module
                elif kind == "swift.protocol":
                    protocols.add(rest.split(" : ", 1)[0].strip())

    def reaches_root(name):
        seen, todo = set(), [name]
        while todo:
            current = todo.pop()
            for target in edges.get(current, ()):
                if target == ROOT_PROTOCOL:
                    return True
                if target not in seen:
                    seen.add(target)
                    todo.append(target)
        return False

    return {name: module for name, module in declared.items() if name not in protocols and reaches_root(name)}


def compiler_flags(modules):
    def run(arguments):
        result = subprocess.run(arguments, capture_output=True, text=True)
        if result.returncode != 0:
            raise Refused("%s failed: %s" % (" ".join(arguments), result.stderr.strip()))
        return result.stdout.strip()
    sdk = run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"])
    machine = run(["uname", "-m"])
    flags = ["-typecheck", "-target", "%s-apple-ios15.0-simulator" % machine, "-sdk", sdk, "-swift-version", "6", "-diagnostic-style", "llvm"]
    if modules:
        products = run([os.path.join(ROOT, "Scripts", "xc.sh"), "products"])
        if not os.path.isdir(os.path.join(products, "ZTronDSP.swiftmodule")):
            raise Refused("there is no build at %s: run Scripts/xc.sh build" % products)
        maps = os.path.join(os.path.normpath(os.path.join(products, "..", "..")), "Intermediates.noindex", "GeneratedModuleMaps-iphonesimulator")
        flags += ["-I", products, "-F", products, "-F", os.path.join(products, "PackageFrameworks")]
        if os.path.isdir(maps):
            for name in sorted(os.listdir(maps)):
                if name.startswith("C") and name.endswith(".modulemap"):
                    flags += ["-Xcc", "-fmodule-map-file=%s" % os.path.join(maps, name)]
    return flags


def typecheck(flags, source, path):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(source)
    result = subprocess.run(["xcrun", "swiftc"] + flags + [path], capture_output=True, text=True)
    output = result.stdout + result.stderr
    if re.search(r"error: (no such module|cannot load module|missing required module|unable to load standard library)", output):
        raise Refused("a module could not be loaded: this is the build, not the matrix\n%s" % "\n".join(output.split("\n")[:6]))
    lines = set()
    for match in re.finditer(r"^%s:(\d+):\d+: error:" % re.escape(path), output, re.MULTILINE):
        lines.add(int(match.group(1)))
    return lines, output


def verdicts(stages, domains, flags, imports, prelude, template, jobs, scratch):
    """One string per stage, one character per domain: "1" where the compiler accepts the stage."""
    head = imports.split("\n") if imports else []
    if prelude:
        head += prelude.rstrip("\n").split("\n")

    def one(index):
        name, expression = stages[index]
        # The stage on its own first: an expression that does not compile would otherwise read
        # as a stage no domain accepts.
        probe = head + [PROBE_TEMPLATE.format(cell=0, stage=expression)]
        failed, output = typecheck(flags, "\n".join(probe) + "\n", os.path.join(scratch, "probe%d.swift" % index))
        if failed:
            raise Refused("the expression of %s does not compile on its own: %s\n%s" % (name, expression, "\n".join(output.split("\n")[:8])))
        body = list(head)
        first = len(body) + 1
        for cell, (_, domain) in enumerate(domains):
            body.append(template.format(cell=cell, domain=domain, stage=expression))
        failed, _ = typecheck(flags, "\n".join(body) + "\n", os.path.join(scratch, "stage%d.swift" % index))
        return "".join("0" if first + cell in failed else "1" for cell in range(len(domains)))

    with concurrent.futures.ThreadPoolExecutor(max_workers=max(jobs, 1)) as pool:
        return list(pool.map(one, range(len(stages))))


def swift_text(stages, domains, rows):
    out = [
        "// Generated by Scripts/order-matrix.sh from Tests/OrderMatrix/stages.txt and domains.txt.",
        "// Do not edit: regenerate (STG-1). `OrderMatrixTests` holds `compiled` against the rules.",
        "import SwiftUI",
        "import ZTronDSP",
        "",
        "/// What the compiler says about every public stage after every domain (ORD-2, tier 1).",
        "enum OrderMatrix {",
        "    static let domains: [(name: String, tag: DomainTag)] = [",
    ]
    for name, swift_type in domains:
        out.append("        (\"%s\", %s.tag)," % (name, swift_type))
    out += ["    ]", "", "    /// One stage per line: its name, and its description as a pipeline holds it.", "    static let stages: [(name: String, descriptions: [StageDescription])] = ["]
    for name, expression in stages:
        out.append("        (\"%s\", descriptions(%s))," % (name, expression))
    out += ["    ]", "", "    /// One line per stage, one character per domain: \"1\" where the stage compiles after it.", "    static let compiled: [String] = ["]
    for (name, _), row in zip(stages, rows):
        out.append("        \"%s\",  // %s" % (row, name))
    out += [
        "    ]",
        "",
        "    // What a stage contributes to a pipeline's description, whichever kind of stage it is.",
        "    private static func descriptions(_ stage: some PipelineStage) -> [StageDescription] { stage.stageDescriptions }",
        "    private static func descriptions(_ stage: some SequenceStage) -> [StageDescription] { stage.stageDescriptions }",
        "    private static func descriptions(_ stage: some ContextDependentStep) -> [StageDescription] { [stage.stageDescription] }",
        "    private static func descriptions<Target>(_ stage: Emit<Target>) -> [StageDescription] { [stage.stageDescription] }",
        "}",
        "",
    ]
    return "\n".join(out)


def document_text(stages, domains, rows):
    out = [
        "# Order matrix",
        "",
        "Every public stage after every signal domain: ✓ where it may stand (ORD-2). Generated by",
        "`Scripts/order-matrix.sh` from what the compiler accepts; the test `OrderMatrixTests` holds the",
        "same table against the order rules that run when a pipeline is attached.",
        "",
        "| Stage | " + " | ".join(name for name, _ in domains) + " |",
        "|---|" + "|".join(":-:" for _ in domains) + "|",
    ]
    for (name, _), row in zip(stages, rows):
        out.append("| `%s` | " % name + " | ".join("✓" if cell == "1" else "·" for cell in row) + " |")
    out += ["", "The domains, as Swift writes them:", ""]
    for name, swift_type in domains:
        out.append("- %s: `%s`" % (name, swift_type))
    out.append("")
    return "\n".join(out)


def main(arguments):
    check = False
    stages_path = os.path.join(ROOT, "Tests", "OrderMatrix", "stages.txt")
    domains_path = os.path.join(ROOT, "Tests", "OrderMatrix", "domains.txt")
    swift_path = os.path.join(ROOT, "Tests", "ZTronDSPTests", "OrderMatrixGenerated.swift")
    document_path = os.path.join(ROOT, "Docs", "OrderMatrix.md")
    digests_path = os.path.join(ROOT, DEFAULT_DIGESTS)
    left_out_path = os.path.join(ROOT, "Tests", "OrderMatrix", "not-in-matrix.txt")
    scan, imports, prelude, template, modules = True, DEFAULT_IMPORTS, None, DEFAULT_TEMPLATE, True
    jobs = os.cpu_count() or 4
    rest = list(arguments)
    try:
        while rest:
            option = rest.pop(0)
            if option == "--check":
                check = True
            elif option == "--no-scan":
                scan = False
            elif option == "--no-modules":
                modules = False
            elif option in ("--stages", "--domains", "--swift", "--document", "--digests", "--not-in-matrix", "--imports", "--prelude",
                            "--template", "--jobs") and rest:
                value = rest.pop(0)
                if option == "--stages":
                    stages_path = value
                elif option == "--domains":
                    domains_path = value
                elif option == "--swift":
                    swift_path = value
                elif option == "--document":
                    document_path = value
                elif option == "--digests":
                    digests_path = value
                elif option == "--not-in-matrix":
                    left_out_path = value
                elif option == "--imports":
                    imports = value
                elif option == "--prelude":
                    with open(value, encoding="utf-8") as handle:
                        prelude = handle.read()
                elif option == "--template":
                    template = value
                else:
                    jobs = int(value)
            elif option in ("-h", "--help"):
                print(__doc__)
                return 0
            else:
                raise Refused("unknown argument %s" % option)

        stages = read_list(stages_path, "list of stages")
        domains = read_list(domains_path, "list of domains")
        problems = []
        if scan:
            declared = public_stages(digests_path)
            left_out = read_list(left_out_path, "list of the stages left out of the matrix", allow_empty=True)
            listed = {name.split(":", 1)[0].strip() for name, _ in stages}
            exempt = {name for name, _ in left_out}
            stages_file, left_out_file = os.path.relpath(stages_path, ROOT), os.path.relpath(left_out_path, ROOT)
            where = os.path.relpath(digests_path if os.path.isabs(digests_path) else os.path.join(ROOT, digests_path), ROOT)
            for name in sorted(set(declared) - listed - exempt):
                problems.append("%s (%s) is a public stage with no line in %s, and none in %s that says why it is not in the matrix" % (
                    name, declared[name], stages_file, left_out_file))
            for name in sorted(listed - set(declared)):
                problems.append("%s has a line in %s and is not a public stage of the digests in %s" % (name, stages_file, where))
            for name in sorted(exempt - set(declared)):
                problems.append("%s has a line in %s and is not a public stage of the digests in %s" % (name, left_out_file, where))
            for name in sorted(listed & exempt):
                problems.append("%s has a line in %s and one in %s: it is in the matrix, or it says why not" % (name, stages_file, left_out_file))

        with tempfile.TemporaryDirectory(prefix="ztd-order-matrix.") as scratch:
            rows = verdicts(stages, domains, compiler_flags(modules), imports, prelude, template, jobs, scratch)
        swift, document = swift_text(stages, domains, rows), document_text(stages, domains, rows)
        accepted = sum(row.count("1") for row in rows)

        if check:
            for path, text in ((swift_path, swift), (document_path, document)):
                current = None
                if os.path.isfile(path):
                    with open(path, encoding="utf-8") as handle:
                        current = handle.read()
                if current != text:
                    problems.append("%s is not what the compiler says today: run Scripts/order-matrix.sh" % os.path.relpath(path, ROOT))
            for problem in problems:
                print("order-matrix: FAIL: %s" % problem)
            if problems:
                return 1
            print("order-matrix: %d stages on %d domains, %d cells accepted; the committed matrix is current" % (len(stages), len(domains), accepted))
            return 0

        for problem in problems:
            print("order-matrix: FAIL: %s" % problem)
        if problems:
            return 1
        for path, text in ((swift_path, swift), (document_path, document)):
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(text)
        print("order-matrix: %d stages on %d domains, %d cells accepted; written to %s and %s" % (
            len(stages), len(domains), accepted, os.path.relpath(swift_path, ROOT), os.path.relpath(document_path, ROOT)))
        return 0
    except Refused as refusal:
        print("order-matrix: %s" % refusal, file=sys.stderr)
        return 2
    except (OSError, ValueError) as error:
        print("order-matrix: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
