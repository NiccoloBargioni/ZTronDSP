#!/bin/bash
# The textual bans of the specification (CI gate 2 of §10.3), in four parts:
#
#   1  WP-002  UB-1, UB-2, UB-3, SZ-2       the UIKit boundary, as UB-5 mechanises it, under Sources/
#                                           and in the gallery's application (no bridge there); the
#                                           layer's `contentsScale` is not named in ZTronDSPUI's code
#   2  WP-010  RT-7(4), ATT-2               hot-path bans (Kernels/, Nodes/, Engine/Run/), `for … in`
#                                           among them (CR-002); no branching on a source's type
#   3  WP-011  APR-1, APR-2, BIND-7, EXT-1  AnyView and Combine need approval; SwiftUI outside
#                                           ZTronDSPUI is the one name Binding; no @_spi, package
#                                           access or @testable in production code, and no
#                                           @testable in the gallery's application
#   4  WP-012  API-6, IMM-2, VIS-1, §9.2, COV-4(a), DEP-4
#                                           no configuration-object names; public setters, `open`,
#                                           `@unchecked Sendable` and shader functions against
#                                           their registers; no shader library made from source
#                                           under Sources/ (the build compiles the shaders)
#
#   Scripts/lint-bans.sh                 all four parts, over the package
#   Scripts/lint-bans.sh --part 2        one part (repeat --part for several)
#   Scripts/lint-bans.sh [--part N] DIR  over another tree shaped like the package (a fixture)
#
# Registers are read from <tree>/Docs/Process; the allow-lists of the UIKit boundary from
# Scripts/lint. Tests/Fixtures and Tests/CompileFixtures are not linted: they hold violations
# on purpose. A violation is printed as `path:line: [RULE] message`.
# Exit status: 0 clean, 1 violations, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/lint_bans.py" "$@"
