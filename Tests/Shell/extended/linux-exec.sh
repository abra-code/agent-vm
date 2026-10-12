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

# box send: each item lands in the box user's ~/Downloads, under its own name, as the account's.
test_send_a_file() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _name="shtest-send-$$"
    printf 'data\n' > "$SCRATCH/$_name.txt"
    /usr/bin/xattr -w com.example.note x "$SCRATCH/$_name.txt"
    run_avm box send "$BOX" "$SCRATCH/$_name.txt" --json
    assert_status 0 || return 1
    assert_out_contains "\"name\" : \"$_name.txt\"" || return 1
    assert_err_contains '"step":"send"' || return 1
    assert_err_events || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c "cd ~/Downloads && cat '$_name.txt' && stat -c '%U %a' '$_name.txt' && ls -A | grep -c '^\._'; ls -A ~/.cache/agent-vm-receiving | wc -l"
    # The content, the account as owner, no file of Mac metadata beside it, no staging left.
    assert_eq "$OUT" $'data\nagent 644\n0\n0' "what arrived" || return 1
    run_avm exec --box "$BOX" -- /bin/rm -f "Downloads/$_name.txt"
    assert_status 0 || return 1
}

# A folder arrives whole: an executable file stays executable, a link stays a link, an empty
# folder and a hidden file are there, and nothing of the Mac's metadata is.
test_send_a_folder_keeps_modes_and_links() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _name="shtest-folder-$$"
    /bin/mkdir -p "$SCRATCH/$_name/bin/empty"
    printf '#!/bin/sh\necho ran in the box\n' > "$SCRATCH/$_name/bin/tool"
    /bin/chmod 755 "$SCRATCH/$_name/bin/tool"
    /usr/bin/xattr -w com.apple.quarantine '0081;00000000;Safari;' "$SCRATCH/$_name/bin/tool"
    printf 'private\n' > "$SCRATCH/$_name/secret.txt"
    /bin/chmod 600 "$SCRATCH/$_name/secret.txt"
    printf 'hidden\n' > "$SCRATCH/$_name/.config"
    /bin/ln -s bin/tool "$SCRATCH/$_name/link"
    run_avm box send "$BOX" "$SCRATCH/$_name"
    assert_status 0 || return 1
    assert_out_contains "Sent $_name to Downloads" || return 1
    run_avm exec --box "$BOX" -- /bin/sh -c "cd ~/Downloads/'$_name' && ./link && readlink link && stat -c '%a' bin/tool secret.txt && cat .config && find . | sort | tr '\n' ' '"
    assert_status 0 || return 1
    assert_eq "$OUT" $'ran in the box\nbin/tool\n755\n600\nhidden\n. ./.config ./bin ./bin/empty ./bin/tool ./link ./secret.txt ' "the folder in the box" || return 1
    run_avm exec --box "$BOX" -- /bin/rm -rf "Downloads/$_name"
    assert_status 0 || return 1
}

# Nothing in Downloads is replaced: the same name again gets a number.
test_send_twice_gets_a_second_name() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _name="shtest-twice-$$"
    printf 'one' > "$SCRATCH/$_name.tar.gz"
    run_avm box send "$BOX" "$SCRATCH/$_name.tar.gz"
    assert_status 0 || return 1
    printf 'two' > "$SCRATCH/$_name.tar.gz"
    run_avm box send "$BOX" "$SCRATCH/$_name.tar.gz"
    assert_status 0 || return 1
    assert_out_contains "Sent $_name.tar.gz to Downloads as $_name.tar 2.gz" || return 1
    run_avm exec --box "$BOX" -- /bin/cat "Downloads/$_name.tar.gz" "Downloads/$_name.tar 2.gz"
    assert_eq "$OUT" "onetwo" "the two files" || return 1
    run_avm exec --box "$BOX" -- /bin/rm -f "Downloads/$_name.tar.gz" "Downloads/$_name.tar 2.gz"
    assert_status 0 || return 1
}

# Names a shell or tar could misread, and one that is not ASCII, arrive as they are.
test_send_a_name_with_spaces_and_non_ascii() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _dir="$SCRATCH/odd"
    /bin/mkdir -p "$_dir"
    # "zazolc" with its Polish letters, written by their bytes so this file stays ASCII.
    local _polish
    _polish="$(printf 'shtest-za\305\274\303\263\305\202\304\207-%s.txt' "$$")"
    local _spaced="shtest a \$(x) 'b' $$.txt"
    local _dash="-shtest-rf-$$"
    local _at="@shtest-$$"
    # A name spelled the Mac's other way, the letter and its accent as two characters, arrives
    # spelled the way Linux tools write it, as one. Only a Linux disk tells the two apart.
    local _decomposed
    _decomposed="$(printf 'shtest-cafe\314\201-%s.txt' "$$")"
    local _composed
    _composed="$(printf 'shtest-caf\303\251-%s.txt' "$$")"
    printf 'p' > "$_dir/$_polish"
    printf 's' > "$_dir/$_spaced"
    printf 'd' > "$_dir/$_dash"
    printf 'a' > "$_dir/$_at"
    printf 'c' > "$_dir/$_decomposed"
    run_avm box send "$BOX" "$_dir/$_polish" "$_dir/$_spaced" "$_dir/$_dash" "$_dir/$_at" "$_dir/$_decomposed"
    assert_status 0 || return 1
    run_avm exec --box "$BOX" -- /bin/cat "Downloads/$_polish" "Downloads/$_spaced" "Downloads/$_dash" "Downloads/$_at" "Downloads/$_composed"
    assert_status 0 || return 1
    assert_eq "$OUT" "psdac" "the five files" || return 1
    run_avm exec --box "$BOX" -- /bin/rm -f "Downloads/$_polish" "Downloads/$_spaced" "Downloads/$_dash" "Downloads/$_at" "Downloads/$_composed"
    assert_status 0 || return 1
}

# A send stopped in the middle of a large file leaves nothing in Downloads and no staging
# folder: the item shows there only once it is whole.
test_send_canceled_leaves_no_staging_folder() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _name="shtest-big-$$.bin"
    # Real bytes: a file of holes would be packed as almost nothing and arrive at once.
    # 2 GB of them: a box takes about 200 MB a second.
    /bin/dd if=/dev/urandom of="$SCRATCH/$_name" bs=1048576 count=2000 2> /dev/null
    local _made=$?
    [ "$_made" -eq 0 ] || { fail "cannot make the 2 GB test file (dd status $_made)"; return 1; }
    "$AGENT_VM" box send "$BOX" "$SCRATCH/$_name" --json > "$SCRATCH/send.out" 2> "$SCRATCH/send.err" &
    local _pid=$!
    wait_for_text "$SCRATCH/send.err" ' MB of ' 30
    local _reached=$?
    kill -INT "$_pid"
    wait "$_pid"
    STATUS=$?
    ERR="$(/bin/cat "$SCRATCH/send.err")"
    printf '%s\n[status %s]\n' "$ERR" "$STATUS" | /usr/bin/tail -n 5
    /bin/rm -f "$SCRATCH/$_name"
    [ "$_reached" -eq 0 ] || { fail "the send did not begin within 30 s"; return 1; }
    assert_status 130 || return 1
    assert_err_contains "Stopped sending $_name" || return 1
    assert_eq "$(/bin/cat "$SCRATCH/send.out" | /usr/bin/tr -d ' \n')" "[]" "the result of a stopped send" || return 1
    # The script is hung up and removes its folder; give it the moment that takes.
    /bin/sleep 4
    run_avm exec --box "$BOX" -- /bin/sh -c "ls -A ~/Downloads | grep -c 'shtest-big'; ls -A ~/.cache/agent-vm-receiving | wc -l"
    assert_eq "$OUT" $'0\n0' "Downloads and the staging folder after the stop" || return 1
    # The box takes the next send.
    printf 'after' > "$SCRATCH/after-$$.txt"
    run_avm box send "$BOX" "$SCRATCH/after-$$.txt"
    assert_status 0 || return 1
    run_avm exec --box "$BOX" -- /bin/rm -f "Downloads/after-$$.txt"
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

# A reader on the Mac that stops reading (a pager, a paused terminal, a slow pipe) holds up its
# own program and nothing else (since 0.7.46): output left unread in a connection stopped every
# connection of the box until the reader read.
test_a_reader_that_stops_does_not_stop_the_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _has
    _has="$("$AGENT_VM" box status "$BOX" --json | /usr/bin/jq -r '(.guestFeatures // []) | index("flow-control") != null')"
    if [ "$_has" != "true" ]; then
        skip "the box's agent-vm-guest has no flow control (agent-vm image update <image> --guest)"
        return 0
    fi
    local _count="$SCRATCH/bytes"
    "$AGENT_VM" exec --box "$BOX" -- /usr/bin/head -c 20000000 /dev/zero | ( /bin/sleep 10; /bin/cat ) | /usr/bin/wc -c > "$_count" &
    local _writer=$!
    /bin/sleep 3
    local _began=$SECONDS
    run_avm exec --box "$BOX" -- /usr/bin/true
    local _took=$((SECONDS - _began))
    wait "$_writer"
    assert_status 0 || return 1
    [ "$_took" -le 4 ] || { fail "another exec took $_took s while one reader was stopped"; return 1; }
    local _bytes="$(/usr/bin/tr -d ' \n' < "$_count")"
    assert_eq "$_bytes" "20000000" "bytes the stopped reader got in the end" || return 1
}
