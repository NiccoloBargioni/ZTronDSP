#!/bin/bash
# Confirms that the dependency graph of the package equals §4.2 (WP-001, DEP-1…DEP-3).
#
#   Scripts/check-dependency-graph.sh                             the manifest and the sources of the package
#   Scripts/check-dependency-graph.sh --manifest-json FILE        a `swift package dump-package` result (- for stdin)
#   Scripts/check-dependency-graph.sh --manifest-json FILE --sources DIR
#
# Compared: targets and edges (CZTronDSPTesting is the C half of ZTronDSPTesting), their order
# (DEP-1), products, platform floor, tools version, Swift 6 mode, function-effect errors of the
# C target, no unsafe flags, no third-party dependency, one test target per target; and, in the
# sources, that no file imports a module its target does not depend on, that ZTronDSPCore
# imports neither AVFAudio nor Metal, and that only ZTronDSPUI imports MetalKit.
# Exit status: 0 equal, 1 deviations, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/dependency_graph.py" "$@"
