#!/bin/bash
#
# Tests/Shell/extended/boxes.sh - a box's life: create, start (and start again), refusals while
# running, stop through the control socket and through a signal to the supervisor, delete.

test_lifecycle() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-life-$$"
    "$AGENT_VM" box delete "$_box" > /dev/null 2>&1
    cleanup_on_exit box "$_box"

    run_avm box create "$_box" --image "$TEST_IMAGE"
    assert_status 0 || return 1
    run_avm box start "$_box" --json
    assert_status 0 || return 1
    assert_json state ready || return 1
    local _pid
    _pid="$(json_value pid)"

    run_avm box start "$_box"
    assert_status 0 || return 1
    assert_out_contains "already running" || return 1
    run_avm box delete "$_box"
    assert_status 1 || return 1
    assert_err_contains "is running" || return 1
    run_avm box list --json
    assert_status 0 || return 1

    run_avm box stop "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /usr/bin/true
    assert_status 125 || return 1

    # A signal to the supervisor (by its PID, from box start) stops the box cleanly too.
    run_avm box start "$_box" --json
    assert_status 0 || return 1
    _pid="$(json_value pid)"
    [ -n "$_pid" ] || { fail "no supervisor pid"; return 1; }
    kill -TERM "$_pid"
    local _waited=0
    while kill -0 "$_pid" 2>/dev/null && [ "$_waited" -lt 60 ]; do
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    kill -0 "$_pid" 2>/dev/null && { fail "the supervisor did not stop within 60 s"; return 1; }
    run_avm box delete "$_box"
    assert_status 0 || return 1
}
