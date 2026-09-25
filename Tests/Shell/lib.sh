#!/bin/bash
#
# Tests/Shell/lib.sh - helpers for the out-of-process tests, sourced by run.sh. Each test is a
# function named test_<name> in a file under fast/ or extended/; it runs in its own subshell
# with a fresh scratch folder ($SCRATCH) and, for fast tests, a private store ($AGENT_VM_HOME).
#
# A test fails by calling fail (or an assert that fails) or by returning non-zero; the usual
# form is `assert_status 0 || return 1`, which also stops the test there. Test output goes to
# a per-test log that run.sh shows when the test fails.

# The binary under test (run.sh sets it; the signed build by default).
AGENT_VM="${AGENT_VM:-}"

# Results of the last run_avm / run_cmd.
OUT=""
ERR=""
STATUS=0

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    # run.sh fails the test even when a caller forgets `|| return 1`.
    : > "$SCRATCH/.failed"
    return 1
}

# Marks the test as skipped (with a reason) and returns 0 so the test function can return.
skip() {
    printf '%s\n' "$*" > "$SCRATCH/.skipped"
    return 0
}

# run_cmd <program> [arguments...]: runs a command, capturing stdout, stderr and status.
run_cmd() {
    "$@" > "$SCRATCH/.out" 2> "$SCRATCH/.err"
    STATUS=$?
    OUT="$(/bin/cat "$SCRATCH/.out")"
    ERR="$(/bin/cat "$SCRATCH/.err")"
    printf '$ %s\n%s\n%s\n[status %s]\n' "$*" "$OUT" "$ERR" "$STATUS"
}

# run_avm [arguments...]: runs agent-vm with run_cmd.
run_avm() {
    run_cmd "$AGENT_VM" "$@"
}

# run_avm_input <text> [arguments...]: runs agent-vm with <text> on stdin.
run_avm_input() {
    local _input="$1"
    shift
    printf '%s' "$_input" | "$AGENT_VM" "$@" > "$SCRATCH/.out" 2> "$SCRATCH/.err"
    STATUS=$?
    OUT="$(/bin/cat "$SCRATCH/.out")"
    ERR="$(/bin/cat "$SCRATCH/.err")"
    printf '$ printf ... | agent-vm %s\n%s\n%s\n[status %s]\n' "$*" "$OUT" "$ERR" "$STATUS"
}

assert_status() {
    [ "$STATUS" -eq "$1" ] || fail "expected status $1, got $STATUS"
}

assert_eq() {
    [ "$1" = "$2" ] || fail "${3:-values differ}: expected [$2], got [$1]"
}

# assert_contains <text> <needle> [message]
assert_contains() {
    case "$1" in
        *"$2"*) return 0 ;;
    esac
    fail "${3:-text} does not contain [$2]"
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "${3:-text} contains [$2]" ;;
    esac
    return 0
}

assert_out_contains() {
    assert_contains "$OUT" "$1" "stdout"
}

assert_err_contains() {
    assert_contains "$ERR" "$1" "stderr"
}

assert_exists() {
    [ -e "$1" ] || [ -L "$1" ] || fail "$1 does not exist"
}

assert_missing() {
    [ ! -e "$1" ] && [ ! -L "$1" ] || fail "$1 exists"
}

# json_value <key path>: a value from $OUT (JSON) by plutil key path ("checks.0.name").
# Arrays and objects give their element count.
json_value() {
    printf '%s' "$OUT" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}

# assert_json <key path> <expected>
assert_json() {
    local _value
    _value="$(json_value "$1")"
    [ "$_value" = "$2" ] || fail "JSON $1: expected [$2], got [$_value]"
}

# assert_err_events: with --json, every line on stderr is a progress event (one JSON object),
# and there is at least one. A failed command's plain "Error: ..." message comes last and may
# span several lines (a recipe step's output), so the check stops there.
assert_err_events() {
    printf '%s\n' "$ERR" | {
        local _line
        local _count=0
        while IFS= read -r _line; do
            case "$_line" in
                '{"event":"'*'}' | '{"'*',"event":"'*'}') _count=$((_count + 1)) ;;
                'Error: '*) break ;;
                *) fail "stderr line is not a progress event: [$_line]"; return 1 ;;
            esac
        done
        [ "$_count" -gt 0 ] || fail "no progress events on stderr"
    }
}

# make_project <folder>: a small project with sources, a git folder and a script.
make_project() {
    local _dir="$1"
    /bin/mkdir -p "$_dir/Sources/App" "$_dir/.git/hooks"
    printf 'hello\n' > "$_dir/README.md"
    printf 'print("hi")\n' > "$_dir/Sources/App/main.swift"
    printf 'ref: refs/heads/main\n' > "$_dir/.git/HEAD"
    printf '#!/bin/sh\necho build\n' > "$_dir/build.sh"
    /bin/chmod 755 "$_dir/build.sh"
}

# fake_image <name> [state]: an image record with stand-in machine files in $AGENT_VM_HOME, so
# box commands can run without a real macOS install.
fake_image() {
    local _name="$1"
    local _state="${2:-ready}"
    local _dir="$AGENT_VM_HOME/Images/$_name"
    /bin/mkdir -p "$_dir"
    /bin/chmod 700 "$AGENT_VM_HOME" "$AGENT_VM_HOME/Images" "$_dir"
    printf 'disk' > "$_dir/Disk.img"
    printf 'aux' > "$_dir/AuxiliaryStorage"
    printf 'hw' > "$_dir/HardwareModel"
    printf 'id' > "$_dir/MachineIdentifier"
    printf 'secret' > "$_dir/Password"
    /bin/chmod 600 "$_dir/Password"
    /bin/cat > "$_dir/image.json" <<EOF
{
  "formatVersion" : 1,
  "name" : "$_name",
  "state" : "$_state",
  "createdAt" : "2026-09-23T10:00:00Z",
  "createdBy" : "test",
  "macOSVersion" : "27.0",
  "macOSBuild" : "26A428",
  "cpuCount" : 4,
  "memoryBytes" : 8589934592,
  "diskBytes" : 68719476736,
  "macAddress" : "da:51:72:d4:e5:72",
  "userName" : "agent",
  "guestProtocol" : 1
}
EOF
}

# ---- Extended tests: real boxes ----------------------------------------------------------

# The ready image extended tests build their boxes from.
TEST_IMAGE="${AGENT_VM_TEST_IMAGE:-dev}"

# image_state <name>: the image's state, or nothing when there is no such image. Returns 1
# when agent-vm cannot list images (a failure, not a reason to skip).
image_state() {
    image_value "$1" state
}

# image_value <name> <key>: a value from the image's record in `image list --json`, or nothing
# when there is no such image or key. Returns 1 when agent-vm cannot list images.
image_value() {
    local _json
    _json="$("$AGENT_VM" image list --json 2>/dev/null)"
    local _listed=$?
    [ "$_listed" -eq 0 ] || return 1
    local _index=0
    local _name
    local _status
    while true; do
        _name="$(printf '%s' "$_json" | /usr/bin/plutil -extract "$_index.name" raw -o - - 2>/dev/null)"
        _status=$?
        [ "$_status" -eq 0 ] || return 0
        if [ "$_name" = "$1" ]; then
            printf '%s' "$_json" | /usr/bin/plutil -extract "$_index.$2" raw -o - - 2>/dev/null
            return 0
        fi
        _index=$((_index + 1))
    done
}

# wait_for_text <file> <text> <seconds>: waits until the file contains the text; returns 1
# when it does not within the time.
wait_for_text() {
    local _waited=0
    local _found
    while [ "$_waited" -lt "$3" ]; do
        _found="$(/usr/bin/grep -F -c -- "$2" "$1" 2>/dev/null)"
        [ -n "$_found" ] && [ "$_found" -gt 0 ] && return 0
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    return 1
}

# start_file_box <name> [box create options...]: for file_setup - creates and starts a box from
# $TEST_IMAGE and records its name in $FILE_SCRATCH/box; records why not in
# $FILE_SCRATCH/no-box when the image is missing.
start_file_box() {
    local _name="$1"
    shift
    local _state
    _state="$(image_state "$TEST_IMAGE")"
    local _listed=$?
    [ "$_listed" -eq 0 ] || { printf 'agent-vm image list --json failed\n' >&2; return 1; }
    if [ "$_state" != "ready" ]; then
        printf 'no ready image %s (set AGENT_VM_TEST_IMAGE)' "$TEST_IMAGE" > "$FILE_SCRATCH/no-box"
        return 0
    fi
    "$AGENT_VM" box delete "$_name" > /dev/null 2>&1
    "$AGENT_VM" box create "$_name" --image "$TEST_IMAGE" "$@" || return 1
    # Recorded before the start, so file_teardown deletes the box even when the start fails.
    printf '%s' "$_name" > "$FILE_SCRATCH/box"
    "$AGENT_VM" box start "$_name" --json > "$FILE_SCRATCH/box-start.json" || return 1
}

# stop_file_box: for file_teardown - stops and deletes the file's box.
stop_file_box() {
    [ -f "$FILE_SCRATCH/box" ] || return 0
    local _name
    _name="$(/bin/cat "$FILE_SCRATCH/box")"
    "$AGENT_VM" box stop "$_name"
    "$AGENT_VM" box delete "$_name"
}

# cleanup_on_exit box|image <name>: in a test that makes its own box or image - when the
# test ends, however it ends (a failed assert, the watchdog), stops and deletes the box or
# deletes the image. Boxes go first, since they are clones of images.
CLEANUP_BOXES=""
CLEANUP_IMAGES=""
cleanup_on_exit() {
    case "$1" in
        box) CLEANUP_BOXES="$CLEANUP_BOXES $2" ;;
        image) CLEANUP_IMAGES="$CLEANUP_IMAGES $2" ;;
        *) fail "cleanup_on_exit: unknown kind $1"; return 1 ;;
    esac
    trap run_cleanup EXIT
}

run_cleanup() {
    local _item
    for _item in $CLEANUP_BOXES; do
        "$AGENT_VM" box stop "$_item" > /dev/null 2>&1
        "$AGENT_VM" box delete "$_item" > /dev/null 2>&1
    done
    for _item in $CLEANUP_IMAGES; do
        "$AGENT_VM" image delete "$_item" > /dev/null 2>&1
    done
}

# require_box: in a test - sets BOX to the file's running box. Returns 1 when the test is
# skipped (no image) and 2 when the box failed to start; use it as
#     require_box || return $(( $? == 1 ? 0 : 1 ))
require_box() {
    if [ -f "$FILE_SCRATCH/no-box" ]; then
        skip "$(/bin/cat "$FILE_SCRATCH/no-box")"
        return 1
    fi
    BOX="$(/bin/cat "$FILE_SCRATCH/box" 2>/dev/null)"
    [ -n "$BOX" ] || { fail "the file's box was not started (see setup.log)"; return 2; }
    return 0
}

# require_image: in a test that makes its own box or image from $TEST_IMAGE. Returns 1 when
# the test is skipped (the image is missing or not ready) and 2 when agent-vm cannot list
# images; use it as
#     require_image || return $(( $? == 1 ? 0 : 1 ))
require_image() {
    local _state
    _state="$(image_state "$TEST_IMAGE")"
    local _listed=$?
    [ "$_listed" -eq 0 ] || { fail "agent-vm image list --json failed"; return 2; }
    if [ "$_state" != "ready" ]; then
        skip "no ready image $TEST_IMAGE"
        return 1
    fi
    return 0
}
