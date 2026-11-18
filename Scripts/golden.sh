#!/bin/bash
# Golden vectors (WP-007, STG-2; CI gate 7 of §10.3).
#
#   Scripts/golden.sh                    run every generator and rewrite the manifest
#   Scripts/golden.sh --only NAME        run one generator and update its part of the manifest
#   Scripts/golden.sh --check            verify the SHA-256 of every generated file against the
#                                        manifest; nothing is run and no oracle needs to be installed
#   Scripts/golden.sh --check --strict   … and fail when a generator is still pending
#   Scripts/golden.sh --reproduce        run the generators in a scratch copy of the tree and compare
#                                        with the committed files (bit for bit, else within --tolerance)
#
# A generator is every Tests/Golden/generators/[a-z]*.py (a file that starts with an underscore
# is a helper: _oracle.py loads the pinned oracles, _golden.py writes the vectors). It is run
# with python3 from that folder and writes into Tests/<Target>Tests/Golden/. A generator that
# writes anything elsewhere lists it: OUTPUTS = ["Tests/…/File.swift"]. Scripts/generate-stress-fixtures.py
# (Sources/ZTronDSPTesting/StressFixtureData.swift) is run as one more generator.
#
# The manifest is Tests/Golden/manifest.json: for each generator, the hash of its source and of
# every file it wrote (*.json, *.f32, *.f64 in the Golden folders, and its OUTPUTS; README.txt
# is not a vector). Pins are in Tests/Golden/generators/requirements.txt: running refuses to
# start when an installed oracle differs from its pin, and a generator that stops because a
# pinned oracle is not installed is recorded as pending.
# Exit status: 0 ok, 1 failure or drift, 2 usage error or a refused run, 3 pending under --strict.

set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/Scripts/lib/golden_runner.py" "$@"
