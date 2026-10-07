#!/bin/bash
#
# Tests/Shell/extended/linux-exec.sh - agent-vm exec and box shell against a real Linux box:
# accounts, streams, statuses, signals, a terminal, the clock, secrets, and that a program
# gets no descriptor it did not ask for. From the ready Linux image
# $AGENT_VM_TEST_LINUX_IMAGE; without it every test is skipped.

file_setup() {
    start_linux_file_box "shtest-lexec-$$"
}

file_teardown() {
    stop_file_box
}

test_exec_runs_as_the_box_user() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- /usr/bin/uname -s
    assert_status 0 || return 1
    assert_eq "$OUT" "Linux" "the system" || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c 'id -un; pwd; echo "$HOME"; echo "$PATH"; echo "$LANG"'
    assert_status 0 || return 1
    assert_eq "$OUT" $'agent\n/home/agent\n/home/agent\n/home/agent/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin\nC.UTF-8' "the program's account and environment" || return 1
    # No way to root from the account.
    run_avm exec --box "$BOX" -- /usr/bin/sudo -n /usr/bin/true
    [ "$STATUS" -ne 0 ] || { fail "the box user ran sudo"; return 1; }
    run_avm exec --box "$BOX" -- /usr/bin/id -nG
    assert_eq "$OUT" "agent" "the box user's groups" || return 1
}

test_exec_as_root() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" --user root -- /bin/sh -c 'id -un; pwd'
    assert_status 0 || return 1
    assert_eq "$OUT" $'root\n/root' "root's program" || return 1
    run_avm exec --box "$BOX" --user nobody-here -- /usr/bin/true
    [ "$STATUS" -ne 0 ] || { fail "exec ran as an account that does not exist"; return 1; }
}

test_exec_streams_and_statuses() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm_input $'b\na\n' exec --box "$BOX" -- sort
    assert_status 0 || return 1
    assert_eq "$OUT" $'a\nb' "stdin through sort" || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c 'echo out; echo err >&2; exit 7'
    assert_status 7 || return 1
    assert_eq "$OUT" "out" "stdout" || return 1
    assert_eq "$ERR" "err" "stderr" || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c 'kill -TERM $$'
    assert_status 143 || return 1
    local _bytes
    _bytes="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/head -c 5000000 /dev/zero | /usr/bin/wc -c | /usr/bin/tr -d ' ')"
    assert_eq "$_bytes" "5000000" "bytes received" || return 1
    run_avm exec --box "$BOX" --env GREETING=hello --cwd /tmp -- /bin/sh -c 'echo "$GREETING"; pwd -P'
    assert_eq "$OUT" $'hello\n/tmp' "environment and folder" || return 1
}

test_a_missing_program_is_127_and_a_missing_folder_126() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- no-such-program
    assert_status 127 || return 1
    assert_err_contains "no-such-program: command not found" || return 1
    run_avm exec --box "$BOX" --cwd /no/such/folder -- /usr/bin/true
    assert_status 126 || return 1
    assert_err_contains "working directory /no/such/folder does not exist" || return 1
    # A file that is there and is no program.
    run_avm exec --box "$BOX" -- /etc/hostname
    [ "$STATUS" -eq 126 ] || [ "$STATUS" -eq 127 ] || { fail "expected 126 or 127 for a file that is no program, got $STATUS"; return 1; }
}

# A program has its three streams and nothing else: not the daemon's sockets, not the status
# pipe its start was reported on.
test_only_three_descriptors() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- /usr/bin/ls /proc/self/fd
    assert_status 0 || return 1
    # 0, 1, 2, and the one ls has open on the folder it lists.
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/tr '\n' ' ')" "0 1 2 3" "descriptors of a program" || return 1
    run_avm exec --box "$BOX" --user root -- /usr/bin/ls /proc/self/fd
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/tr '\n' ' ')" "0 1 2 3" "descriptors of root's program" || return 1
}

test_signals_and_the_second_signal() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    "$AGENT_VM" exec --box "$BOX" -- /usr/bin/sleep 30 &
    local _pid=$!
    /bin/sleep 2
    kill -INT "$_pid"
    wait "$_pid"
    assert_eq "$?" "130" "status after SIGINT" || return 1
    local _marker="sleep 319"
    "$AGENT_VM" exec --box "$BOX" -- /bin/sh -c "trap '' INT TERM; $_marker; $_marker" 2>"$SCRATCH/second-signal.err" &
    _pid=$!
    /bin/sleep 2
    kill -INT "$_pid"
    kill -INT "$_pid"
    /bin/sleep 2
    kill -0 "$_pid" 2>/dev/null || { fail "exec ended on the first signal although the program ignores it"; return 1; }
    kill -INT "$_pid"
    wait "$_pid"
    assert_eq "$?" "130" "status after the second SIGINT" || return 1
    assert_contains "$(/bin/cat "$SCRATCH/second-signal.err")" "did not end; closing the connection" "exec's stderr" || return 1
    /bin/sleep 5
    run_avm exec --box "$BOX" -- /usr/bin/pgrep -c -f "^$_marker"
    assert_eq "$OUT" "0" "processes left in the guest" || return 1
}

test_a_killed_client_ends_the_program() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _marker="sleep 317"
    "$AGENT_VM" exec --box "$BOX" -- /bin/sh -c "$_marker" &
    local _pid=$!
    /bin/sleep 2
    run_avm exec --box "$BOX" -- /usr/bin/pgrep -c -f "^$_marker"
    [ -n "$OUT" ] && [ "$OUT" != "0" ] || { fail "the program was not running before the kill"; return 1; }
    kill -KILL "$_pid"
    wait "$_pid" 2>/dev/null
    /bin/sleep 5
    run_avm exec --box "$BOX" -- /usr/bin/pgrep -c -f "^$_marker"
    assert_eq "$OUT" "0" "processes left in the guest" || return 1
}

test_a_terminal_session() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    on_terminal ':' /bin/sh -c "stty rows 30 cols 100; \"$AGENT_VM\" exec -t --box $BOX -- /bin/sh -c 'tty; stty size; echo TERM=\$TERM'"
    assert_status 0 || return 1
    assert_out_contains "/dev/pts/" || return 1
    assert_out_contains "30 100" || return 1
    assert_out_contains "TERM=" || return 1
    # Control-C on the terminal ends the program in the box.
    on_terminal "/bin/sleep 3; printf '\\003'" "$AGENT_VM" exec -t --box "$BOX" -- /usr/bin/sleep 60
    assert_status 130 || return 1
    # The local terminal is as it was afterwards.
    on_terminal ':' /bin/sh -c "/bin/stty -g > '$SCRATCH/tty-before'; \"$AGENT_VM\" exec -t --box $BOX -- /bin/sh -c 'exit 5'; echo exec-status=\$?; /bin/stty -g > '$SCRATCH/tty-after'"
    assert_out_contains "exec-status=5" || return 1
    assert_eq "$(/bin/cat "$SCRATCH/tty-after")" "$(/bin/cat "$SCRATCH/tty-before")" "the terminal's settings after exec -t" || return 1
}

test_box_shell_is_a_login_shell() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    # bash says of itself whether it is a login shell, which reads the profile that puts
    # ~/.local/bin in the path.
    on_terminal "/bin/sleep 3; printf 'shopt -q login_shell && echo shell-\$((6*7)) \$(whoami) login\\r'; /bin/sleep 1; printf 'exit 3\\r'" "$AGENT_VM" box shell "$BOX"
    assert_status 3 || return 1
    assert_out_contains "shell-42 agent login" || return 1
    on_terminal "/bin/sleep 3; printf 'echo I am \$(whoami)\\r'; /bin/sleep 1; printf 'exit\\r'" "$AGENT_VM" box shell "$BOX" --user root
    assert_status 0 || return 1
    assert_out_contains "I am root" || return 1
}

test_the_clock_is_set() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box sync-clock "$BOX" --json
    assert_status 0 || return 1
    local _guest
    _guest="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/date +%s)"
    local _mac
    _mac="$(/bin/date +%s)"
    local _apart=$(( _guest > _mac ? _guest - _mac : _mac - _guest ))
    [ "$_apart" -le 3 ] || { fail "the guest's clock is $_apart s from the Mac's"; return 1; }
    assert_contains "$(/bin/cat "$(box_folder "$BOX")/supervisor.log")" "Clock: set the guest's time (boot" "the supervisor's log" || return 1
}

test_secrets_reach_the_program_and_the_exec_log_records_it() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _secret="sk-shtest-$$-$RANDOM"
    run_cmd /usr/bin/env AVM_SHTEST_KEY="$_secret" "$AGENT_VM" exec --box "$BOX" --env AVM_SHTEST_KEY -- /bin/sh -c 'printf "%s\n" "$AVM_SHTEST_KEY"'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_secret" "the program's variable" || return 1
    local _found
    _found="$(/usr/bin/grep -rl --exclude=Disk.img -e "$_secret" "$(box_folder "$BOX")" 2>/dev/null)"
    assert_eq "$_found" "" "files in the box folder holding the value" || return 1
    run_avm box execlog "$BOX" --json
    assert_status 0 || return 1
    assert_contains "$OUT" "AVM_SHTEST_KEY" "the exec log" || return 1
    assert_not_contains "$OUT" "$_secret" "the exec log" || return 1
}
