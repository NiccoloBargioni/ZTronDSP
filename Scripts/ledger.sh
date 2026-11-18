#!/bin/bash
# The delivery ledger, Docs/Process/ledger.md (WP-008, §11.9).
#
#   Scripts/ledger.sh --update   re-derive the ledger from §12, keeping everything that was filled in
#   Scripts/ledger.sh --check    compare the ledger with §12 and with the definition of done (§11.8)
#
# Options: --spec FILE, --ledger FILE. Exit status: 0 consistent, 1 findings, 2 usage error.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/ledger.py" "$@"
