`manifest.json` is a `swift package dump-package` result that equals §4.2. The self-test derives
every wrong manifest from it with `jq`, so a fixture cannot drift from the real shape of a dump.
`sources-clean` and `sources-bad` are trees whose `Sources/` the import scan reads.
