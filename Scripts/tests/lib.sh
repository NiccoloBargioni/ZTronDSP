# Sourced by the self-tests of the scripts. bash 3.2.
#
#   expect_status <status> <name> <command …>   runs the command; keeps its output in LAST_OUTPUT
#   expect_contains <name> <text>               LAST_OUTPUT holds the text
#   expect_lacks <name> <text>                  LAST_OUTPUT does not hold the text
#   make_scratch <name>                         SCRATCH: a folder that is removed at exit
#   reset_folder <path inside SCRATCH>          an empty folder at that path
#   finish                                      prints the tally; its status is the suite's
#
# A failed check shows the first 15 lines of the output; ZTD_TEST_LINES=200 shows more.

TESTS_RUN=0
TESTS_FAILED=0
LAST_OUTPUT=""
LAST_STATUS=0

pass() {
    TESTS_RUN=$((TESTS_RUN + 1))
    printf '  ok    %s\n' "$1"
}

fail() {
    TESTS_RUN=$((TESTS_RUN + 1))
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf '  FAIL  %s\n' "$1"
    if [ -n "${2:-}" ]; then
        printf '%s\n' "$2" | sed 's/^/          | /' | head -"${ZTD_TEST_LINES:-15}"
    fi
}

expect_status() {
    local expected="$1" name="$2"
    shift 2
    LAST_OUTPUT="$("$@" 2>&1)"
    LAST_STATUS=$?
    if [ "$LAST_STATUS" -eq "$expected" ]; then
        pass "$name"
    else
        fail "$name (exit $LAST_STATUS, expected $expected)" "$LAST_OUTPUT"
    fi
}

expect_contains() {
    local name="$1" text="$2"
    case "$LAST_OUTPUT" in
        *"$text"*) pass "$name" ;;
        *) fail "$name (output lacks: $text)" "$LAST_OUTPUT" ;;
    esac
}

expect_lacks() {
    local name="$1" text="$2"
    case "$LAST_OUTPUT" in
        *"$text"*) fail "$name (output holds: $text)" "$LAST_OUTPUT" ;;
        *) pass "$name" ;;
    esac
}

# make_scratch <name>: SCRATCH becomes a new folder under the temporary directory; it is removed
# when the test exits. reset_folder <path> empties a folder inside it. Both refuse a path that
# is not what they made, so a failed mktemp can never turn a clean-up into something else.
make_scratch() {
    local base="${TMPDIR:-/tmp}"
    base="${base%/}"
    SCRATCH="$(mktemp -d "$base/ztd-$1.XXXXXX")" || { echo "the self-test cannot make a scratch folder" >&2; exit 1; }
    case "$SCRATCH" in
        "$base/ztd-$1".??????) ;;
        *) echo "the self-test got an unexpected scratch folder: '$SCRATCH'" >&2; exit 1 ;;
    esac
    trap 'remove_scratch' EXIT
}

remove_scratch() {
    case "${SCRATCH:-}" in
        */ztd-*.??????) [ -d "$SCRATCH" ] && rm -rf "$SCRATCH" ;;
    esac
    return 0
}

reset_folder() {
    case "$1" in
        "${SCRATCH:?}"/?*) rm -rf "$1" && mkdir -p "$1" ;;
        *) echo "reset_folder: '$1' is not inside the scratch folder" >&2; exit 1 ;;
    esac
}

finish() {
    printf '%d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
