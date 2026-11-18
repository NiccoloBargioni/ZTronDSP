#!/bin/bash
# The mechanical cross-check of the specification (§13.1): identifiers, dependencies, lenses,
# the traceability table of §2 and every other reference to a work package.
#
#   Scripts/spec-crosscheck.sh [path/to/specification.md]
#
# It reads the specification and never edits it. Exit status: 0 no defect, 1 defects found,
# 2 usage error. Readings the check had to choose (a name that exists only as its parts, what
# `all` stands for) are printed as notes and do not fail it.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/spec_crosscheck.py" "$@"
