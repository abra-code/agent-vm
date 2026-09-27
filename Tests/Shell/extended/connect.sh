#!/bin/bash
#
# Tests/Shell/extended/connect.sh - agent-vm connect, as avm, on a real box: a command in the
# shared folder with its status passed back, a stopped box started (and left running, with no
# owner), the terminal restored, and a box busy with another folder refused. One box from
# $TEST_IMAGE for the file; script(1) provides the terminal (on_terminal).

file_setup() {
    start_file_box "shtest-conn-$$"
}

file_teardown() {
    stop_file_box
}

test_connect_runs_a_command_in_the_folder() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    make_project "$SCRATCH/project"
    on_terminal ':' /bin/sh -c "cd '$SCRATCH/project' && '$SCRATCH/avm' $BOX -- /bin/sh -c 'pwd -P; echo in-\$((6*7))'"
    assert_status 0 || return 1
    assert_out_contains "Sharing $SCRATCH/project (read-write)" || return 1
    assert_out_contains "$(cd "$SCRATCH/project" && /bin/pwd -P)" || return 1
    assert_out_contains "in-42" || return 1
    assert_out_contains "Box $BOX keeps running" || return 1
    run_avm box status "$BOX" --json
    assert_json state running || return 1
    # The choice is remembered for the folder.
    run_avm_link list --json --project "$SCRATCH/project"
    assert_json remembered.box "$BOX" || return 1
}

test_connect_passes_the_program_status() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    on_terminal ':' "$SCRATCH/avm" "$BOX" --no-project -- /bin/sh -c 'exit 7'
    assert_status 7 || return 1
    # Also when started with SIGCHLD ignored, which exec passes on: the child is not reaped unseen.
    on_terminal ':' /usr/bin/perl -e '$SIG{CHLD} = "IGNORE"; exec @ARGV' "$SCRATCH/avm" "$BOX" --no-project -- /bin/sh -c 'exit 7'
    assert_status 7 || return 1
}

test_connect_starts_a_stopped_kept_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    run_avm box stop "$BOX"
    assert_status 0 || return 1
    on_terminal ':' "$SCRATCH/avm" "$BOX" --no-project -- /usr/bin/true
    assert_status 0 || return 1
    assert_out_contains "Starting box $BOX" || return 1
    assert_out_contains "Box $BOX is running" || return 1
    run_avm box status "$BOX" --json
    assert_json state running || return 1
    # Never owned by connect: it keeps running after connect exits.
    [ -z "$(json_value ownerPid)" ] || { fail "the box has an owner: $(json_value ownerPid)"; return 1; }
}

test_connect_restores_the_terminal() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    on_terminal ':' /bin/sh -c "/bin/stty -g > '$SCRATCH/tty-before'; '$SCRATCH/avm' $BOX --no-project -- /bin/sh -c 'exit 5'; echo avm-status=\$?; /bin/stty -g > '$SCRATCH/tty-after'"
    assert_status 0 || return 1
    assert_out_contains "avm-status=5" || return 1
    local _before
    _before="$(/bin/cat "$SCRATCH/tty-before")"
    local _after
    _after="$(/bin/cat "$SCRATCH/tty-after")"
    assert_contains "$_before" ":" "stty -g before avm" || return 1
    assert_eq "$_after" "$_before" "terminal settings after avm" || return 1
}

test_connect_refuses_a_busy_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    local _first="$SCRATCH/first"
    local _second="$SCRATCH/second"
    make_project "$_first"
    make_project "$_second"
    "$AGENT_VM" exec --box "$BOX" --project "$_first" -- /bin/sleep 20 &
    local _pid=$!
    /bin/sleep 5
    on_terminal ':' "$SCRATCH/avm" "$BOX" --project "$_second" -- /usr/bin/true
    kill -INT "$_pid"
    wait "$_pid" 2>/dev/null
    assert_status 1 || return 1
    assert_out_contains "is running programs on $_first" || return 1
}
