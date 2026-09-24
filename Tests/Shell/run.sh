#!/bin/bash
#
# Tests/Shell/run.sh - out-of-process tests: shell scripts that drive the real agent-vm binary.
#
# Usage: Tests/Shell/run.sh [fast|extended|all] [--filter <text>] [--agent-vm <path>] [--keep]
#
#   fast      seconds, no virtual machine: the CLI, sessions, the image and box stores, recipe
#             and network-rule checks, each against a private store (default)
#   extended  minutes, real virtual machines: boxes, exec, networking, project shares, derived
#             images; uses the default store (or $AGENT_VM_TEST_HOME) and a ready image named
#             $AGENT_VM_TEST_IMAGE (default: dev); tests skip when it is missing
#   all       both
#   --filter  run only tests whose file or function name contains <text>
#   --agent-vm the binary to test (default: .build/signed/release/agent-vm from Scripts/build.sh)
#   --keep    keep every test's scratch folder (failed tests' folders are always kept)
#
# Each test_<name> function in fast/*.sh or extended/*.sh runs in its own subshell. A file may
# define file_setup and file_teardown, run once around its tests (extended tests share one box
# per file that way). A test that runs longer than 60 s (fast) or 15 minutes (extended) is
# stopped with its whole process group and fails. Exit status: 0 when nothing failed.

REPO_ROOT="$(cd "$(/usr/bin/dirname "$0")/../.." && /bin/pwd -P)"
TESTS_DIR="$REPO_ROOT/Tests/Shell"
TIER="fast"
FILTER=""
KEEP=0
AGENT_VM="$REPO_ROOT/.build/signed/release/agent-vm"

die() {
    printf 'run.sh: %s\n' "$1" >&2
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        fast|extended|all)
            TIER="$1"
            ;;
        --filter)
            shift
            [ $# -gt 0 ] || die "--filter needs a value"
            FILTER="$1"
            ;;
        --agent-vm)
            shift
            [ $# -gt 0 ] || die "--agent-vm needs a value"
            AGENT_VM="$1"
            ;;
        --keep)
            KEEP=1
            ;;
        -h|--help)
            /usr/bin/sed -n '5,15p' "$0" | /usr/bin/sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            die "unknown argument: $1 (see --help)"
            ;;
    esac
    shift
done

[ -x "$AGENT_VM" ] || die "no agent-vm at $AGENT_VM; build it with Scripts/build.sh"
export AGENT_VM
# Scratch folders live under /private/tmp: control socket paths must stay under 104 bytes.
SCRATCH_ROOT="$(/usr/bin/mktemp -d /private/tmp/avm-tests.XXXXXX)"
status=$?
[ "$status" -eq 0 ] && [ -d "$SCRATCH_ROOT" ] || die "cannot create a scratch folder"
RESULTS="$SCRATCH_ROOT/results"
: > "$RESULTS"

case "$TIER" in
    fast) tiers="fast" ;;
    extended) tiers="extended" ;;
    all) tiers="fast extended" ;;
esac

now() {
    /bin/date +%s
}

# Ctrl-C (or TERM to the process group) during a file: stops the running test's process
# group, runs file_teardown so no box is left running, and ends the file's subshell with 130.
interrupted() {
    trap '' INT TERM
    if [ -n "$TEST_PGID" ]; then
        kill -TERM -- "-$TEST_PGID" 2>/dev/null
        /bin/sleep 2
        kill -KILL -- "-$TEST_PGID" 2>/dev/null
        wait "$TEST_PGID" 2>/dev/null
    fi
    if [ -n "$TEARDOWN" ]; then
        printf 'interrupted: running file_teardown\n' >&2
        SCRATCH="$FILE_SCRATCH"
        file_teardown >> "$FILE_SCRATCH/setup.log" 2>&1
    fi
    exit 130
}

# run_file <tier> <file>: runs every test function of one file, appending to $RESULTS.
run_file() {
    local _tier="$1"
    local _file="$2"
    local _base
    _base="$(/usr/bin/basename "$_file" .sh)"
    (
        # shellcheck source=lib.sh
        source "$TESTS_DIR/lib.sh"
        source "$_file"
        local _loaded=$?
        if [ "$_loaded" -ne 0 ]; then
            # A syntax error would otherwise drop the file's tests without a failure.
            printf 'FAIL  %s/%s  (the file does not load; see the error above)\n' "$_tier" "$_base"
            printf 'FAIL\n' >> "$RESULTS"
            exit 0
        fi
        local _functions
        _functions="$(declare -F | /usr/bin/awk '{print $3}' | /usr/bin/grep '^test_')"
        local _selected=""
        local _name
        for _name in $_functions; do
            case "$_base.$_name" in
                *"$FILTER"*) _selected="$_selected $_name" ;;
            esac
        done
        [ -n "$_selected" ] || exit 0

        FILE_SCRATCH="$SCRATCH_ROOT/$_tier-$_base"
        /bin/mkdir -p "$FILE_SCRATCH"
        export FILE_SCRATCH
        if [ "$_tier" = "fast" ]; then
            export AGENT_VM_HOME="$FILE_SCRATCH/home"
        elif [ -n "${AGENT_VM_TEST_HOME:-}" ]; then
            export AGENT_VM_HOME="$AGENT_VM_TEST_HOME"
        fi
        TEST_PGID=""
        TEARDOWN=""
        declare -F file_teardown > /dev/null && TEARDOWN=1
        trap interrupted INT TERM
        local _setup_failed=""
        if declare -F file_setup > /dev/null; then
            SCRATCH="$FILE_SCRATCH"
            file_setup > "$FILE_SCRATCH/setup.log" 2>&1
            if [ $? -ne 0 ]; then
                _setup_failed="file_setup failed (see $FILE_SCRATCH/setup.log)"
            fi
        fi

        for _name in $_selected; do
            SCRATCH="$FILE_SCRATCH/$_name"
            /bin/mkdir -p "$SCRATCH"
            local _log="$SCRATCH/log"
            local _began
            _began="$(now)"
            local _result
            if [ -n "$_setup_failed" ]; then
                printf '%s\n' "$_setup_failed" > "$_log"
                _result="FAIL"
            else
                # Each test runs as its own process group (job control on), so a watchdog can
                # stop it, and everything it started, by that group's ID.
                set -m
                (
                    if [ "$_tier" = "fast" ]; then
                        export AGENT_VM_HOME="$SCRATCH/home"
                        /bin/mkdir -p "$AGENT_VM_HOME"
                    fi
                    cd "$SCRATCH" || exit 1
                    "$_name"
                ) < /dev/null > "$_log" 2>&1 &
                # stdin is /dev/null: a background process group that reads a terminal is
                # stopped (SIGTTIN), and agent-vm exec always reads stdin.
                local _pid=$!
                TEST_PGID="$_pid"
                set +m
                local _limit=60
                [ "$_tier" = "extended" ] && _limit=900
                local _timed_out=0
                while kill -0 "$_pid" 2>/dev/null; do
                    if [ $(( $(now) - _began )) -ge "$_limit" ]; then
                        _timed_out=1
                        kill -TERM -- "-$_pid" 2>/dev/null
                        # Up to 30 s for the test's EXIT trap (cleanup_on_exit) to stop its boxes.
                        local _grace=0
                        while kill -0 "$_pid" 2>/dev/null && [ "$_grace" -lt 150 ]; do
                            /bin/sleep 0.2
                            _grace=$((_grace + 1))
                        done
                        kill -KILL -- "-$_pid" 2>/dev/null
                        break
                    fi
                    /bin/sleep 0.2
                done
                wait "$_pid"
                local _status=$?
                # Anything the test left running in the background (its group outlives it).
                kill -KILL -- "-$_pid" 2>/dev/null
                TEST_PGID=""
                if [ "$_timed_out" -eq 1 ]; then
                    printf 'FAIL: timed out after %ss\n' "$_limit" >> "$_log"
                    _result="FAIL"
                elif [ "$_status" -ne 0 ] || [ -f "$SCRATCH/.failed" ]; then
                    _result="FAIL"
                elif [ -f "$SCRATCH/.skipped" ]; then
                    _result="SKIP"
                else
                    _result="PASS"
                fi
            fi
            local _elapsed=$(( $(now) - _began ))
            local _line="$_result  $_tier/$_base.$_name  (${_elapsed}s)"
            if [ "$_result" = "SKIP" ]; then
                _line="$_line  $(/bin/cat "$SCRATCH/.skipped")"
            fi
            printf '%s\n' "$_line"
            printf '%s\n' "$_result" >> "$RESULTS"
            if [ "$_result" = "FAIL" ]; then
                /usr/bin/tail -n 40 "$_log" | /usr/bin/sed 's/^/        /'
                printf '        (scratch folder kept: %s)\n' "$SCRATCH"
            elif [ "$KEEP" -eq 0 ]; then
                /bin/rm -rf "$SCRATCH"
            fi
        done

        if declare -F file_teardown > /dev/null; then
            SCRATCH="$FILE_SCRATCH"
            file_teardown >> "$FILE_SCRATCH/setup.log" 2>&1
        fi
    )
}

# The file's subshell handles Ctrl-C (see interrupted); this shell waits for it, then stops.
trap 'printf "\nInterrupted; scratch folders are under %s\n" "$SCRATCH_ROOT" >&2; exit 130' INT TERM

printf 'agent-vm under test: %s (%s)\n' "$AGENT_VM" "$("$AGENT_VM" --version 2>/dev/null)"
suite_began="$(now)"
for tier in $tiers; do
    for file in "$TESTS_DIR/$tier"/*.sh; do
        [ -f "$file" ] || continue
        run_file "$tier" "$file"
    done
done

passed="$(/usr/bin/grep -c '^PASS$' "$RESULTS")"
failed="$(/usr/bin/grep -c '^FAIL$' "$RESULTS")"
skipped="$(/usr/bin/grep -c '^SKIP$' "$RESULTS")"
printf '\n%s passed, %s failed, %s skipped in %ss\n' "$passed" "$failed" "$skipped" "$(( $(now) - suite_began ))"
if [ "$failed" -ne 0 ]; then
    printf 'Scratch folders of failed tests are under %s\n' "$SCRATCH_ROOT"
    exit 1
fi
if [ "$KEEP" -eq 0 ]; then
    /bin/rm -rf "$SCRATCH_ROOT"
fi
exit 0
