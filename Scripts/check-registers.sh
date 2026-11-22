#!/bin/bash
# Checks the audit of the algorithm and stability registers (WP-905a…d, §7.2, §7.3, §7.5) mechanically.
#
#   Scripts/check-registers.sh                     the newest Docs/Numerics/register-audit-*.md
#   Scripts/check-registers.sh --audit FILE        another audit table
#   Scripts/check-registers.sh --root DIR [--spec FILE] [--numerics DIR]
#
# One row per row of §7.2, numbered and named as there, each with its twin in §7.5 (NUMS-1); no
# empty cell; a dated currency check per row; every file a row names exists, and every test it
# names is declared in the file it is named with; every ALG package of §12 is in exactly one row;
# every note of Docs/Numerics is named by a row or listed as supplementary. Details:
# Scripts/lib/registers.py.
# Exit status: 0 the table holds, 1 a check failed, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/registers.py" "$@"
