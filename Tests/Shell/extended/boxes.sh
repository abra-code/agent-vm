#!/bin/bash
#
# Tests/Shell/extended/boxes.sh - a box's life: create, start (and start again), its status,
# refusals while running, stop through the control socket and through a signal to the
# supervisor, delete.

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

    # box status asks the supervisor and changes nothing; the supervisor's argv[0] is its path.
    run_avm --version
    local _version="$OUT"
    run_avm box status "$_box" --json
    assert_status 0 || return 1
    assert_json state ready || return 1
    assert_json running true || return 1
    assert_json pid "$_pid" || return 1
    assert_json supervisorVersion "$_version" || return 1
    assert_json activeExecs 0 || return 1
    assert_json guestFeatures.0 terminal || return 1
    local _path
    _path="$(json_value supervisorPath)"
    [ -n "$_path" ] && [ -n "$(json_value startedAt)" ] || { fail "no supervisor path or start time"; return 1; }
    run_cmd /bin/ps -o command= -p "$_pid"
    assert_out_contains "$_path box serve $_box" || return 1

    # A program run through exec counts while it runs, from any client.
    "$AGENT_VM" exec --box "$_box" -- /bin/sleep 5 > /dev/null 2>&1 &
    local _exec=$!
    local _seen=""
    local _tries=0
    while [ -z "$_seen" ] && [ "$_tries" -lt 20 ]; do
        run_avm box status "$_box" --json
        [ "$(json_value activeExecs)" = "1" ] && _seen=yes
        _tries=$((_tries + 1))
        [ -n "$_seen" ] || /bin/sleep 0.2
    done
    wait "$_exec"
    [ -n "$_seen" ] || { fail "box status never counted the running exec"; return 1; }

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
    run_avm box status "$_box" --json
    assert_json state stopped || return 1
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
