#!/bin/bash
#
# Tests/Shell/extended/exec.sh - agent-vm exec against a real box: output and input streams,
# exit statuses, signals, environment, accounts, and what happens when the client dies.

file_setup() {
    start_file_box "shtest-exec-$$"
}

file_teardown() {
    stop_file_box
}

test_runs_a_program_in_the_guest() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- uname -sr
    assert_status 0 || return 1
    assert_out_contains "Darwin" || return 1
    run_avm exec --box "$BOX" -- /usr/bin/id -un
    assert_eq "$OUT" "agent" "default account" || return 1
    run_avm exec --box "$BOX" --user root -- /usr/bin/id -un
    assert_eq "$OUT" "root" "--user root" || return 1
}

test_streams_and_statuses() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm_input $'b\na\n' exec --box "$BOX" -- sort
    assert_status 0 || return 1
    assert_eq "$OUT" $'a\nb' "stdin through sort" || return 1

    run_avm exec --box "$BOX" -- /bin/sh -c 'echo out; echo err >&2; exit 3'
    assert_status 3 || return 1
    assert_eq "$OUT" "out" "stdout" || return 1
    assert_eq "$ERR" "err" "stderr" || return 1

    run_avm exec --box "$BOX" -- no-such-program
    assert_status 127 || return 1
    assert_err_contains "command not found" || return 1
    run_avm exec --box "$BOX" --cwd /no/such/folder -- /usr/bin/true
    assert_status 126 || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c 'kill -TERM $$'
    assert_status 143 || return 1
}

test_environment_and_working_folder() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" --env GREETING=hello --cwd /tmp -- /bin/sh -c 'echo "$GREETING"; /bin/pwd -P'
    assert_status 0 || return 1
    assert_eq "$OUT" $'hello\n/private/tmp' "environment and folder" || return 1
}

test_large_output_arrives_whole() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _bytes
    _bytes="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/head -c 50000000 /dev/zero | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    assert_eq "$_bytes" "50000000" "bytes received" || return 1
}

test_a_closed_output_ends_exec_with_141() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    # PIPESTATUS must be read inside the substitution: outside it describes the assignment.
    local _result
    _result="$("$AGENT_VM" exec --box "$BOX" -- yes | /usr/bin/head -1; printf 'status %s' "${PIPESTATUS[0]}")"
    assert_eq "$_result" $'y\nstatus 141' "first line and exec's status" || return 1
}

test_signals_reach_the_program() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    "$AGENT_VM" exec --box "$BOX" -- /bin/sleep 30 &
    local _pid=$!
    /bin/sleep 3
    kill -INT "$_pid"
    wait "$_pid"
    assert_eq "$?" "130" "status after SIGINT" || return 1
}

test_killing_the_client_ends_the_program() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _marker="sleep 317"
    "$AGENT_VM" exec --box "$BOX" -- /bin/sh -c "$_marker" &
    local _pid=$!
    /bin/sleep 3
    # Otherwise a program that never started would pass the check below.
    run_avm exec --box "$BOX" -- /bin/sh -c "/bin/ps -axo command | /usr/bin/grep -c '^$_marker'"
    [ -n "$OUT" ] && [ "$OUT" != "0" ] || { fail "the program was not running before the kill"; return 1; }
    kill -KILL "$_pid"
    wait "$_pid" 2>/dev/null
    # SIGHUP at once, SIGKILL after 3 s: give the guest a moment.
    /bin/sleep 5
    run_avm exec --box "$BOX" -- /bin/sh -c "/bin/ps -axo command | /usr/bin/grep -c '^$_marker'"
    assert_eq "$OUT" "0" "processes left in the guest" || return 1
}
