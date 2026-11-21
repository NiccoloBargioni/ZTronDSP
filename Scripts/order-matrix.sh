#!/bin/bash
# The order matrix (WP-328; ORD-2; CI gate 3 of §10.3): every public stage on every domain.
#
#   Scripts/order-matrix.sh            ask the compiler about every cell and write the matrix
#   Scripts/order-matrix.sh --check    fail when the committed matrix is not what the compiler
#                                      says today, or does not hold every public stage
#
# The stages are the lines of Tests/OrderMatrix/stages.txt (`Type | an expression that makes
# one`), the domains those of Tests/OrderMatrix/domains.txt (`name | Swift type`). Every public
# stage of the API digests (Docs/API) has a line there, or one in
# Tests/OrderMatrix/not-in-matrix.txt that says why it is not in the matrix. The matrix is
# written to Tests/ZTronDSPTests/OrderMatrixGenerated.swift, where the test OrderMatrixTests
# holds it against the DomainRule of every stage (tier 1 against tier 2), and to
# Docs/OrderMatrix.md. A package that adds a stage adds its line and regenerates (STG-1).
#
# It type-checks against the modules of the last build (Scripts/xc.sh build), as
# Scripts/compile-fixtures.sh does. Other options are for its self-test: see
# Scripts/lib/order_matrix.py.
#
# Exit status: 0 ok, 1 the matrix is out of date or incomplete, 2 usage error or no build.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/order_matrix.py" "$@"
