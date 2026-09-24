#!/bin/bash
#
# Tests/Shell/extended/terminal.sh - programs on a terminal in a real box (exec --tty, box shell),
# the exec log, and image update-guest. The file derives its own image from $TEST_IMAGE, which
# also puts this agent-vm's guest daemon into it (about 30 s), and runs one box from that.
# script(1) provides the local terminal that --tty needs.

file_setup() {
    local _image="shtest-term-$$"
    printf '%s' "$_image" > "$FILE_SCRATCH/image"
    local _state
    _state="$(image_state "$TEST_IMAGE")"
    local _listed=$?
    [ "$_listed" -eq 0 ] || { printf 'agent-vm image list --json failed\n' >&2; return 1; }
    if [ "$_state" != "ready" ]; then
        printf 'no ready image %s (set AGENT_VM_TEST_IMAGE)' "$TEST_IMAGE" > "$FILE_SCRATCH/no-box"
        return 0
    fi
    /bin/mkdir -p "$FILE_SCRATCH/recipe"
    printf '{"version": 1, "description": "terminal tests", "steps": [{"name": "noop", "run": "true"}]}\n' > "$FILE_SCRATCH/recipe/recipe.json"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    "$AGENT_VM" image create "$_image" --from "$TEST_IMAGE" --recipe "$FILE_SCRATCH/recipe/recipe.json" || return 1
    # start_file_box builds from $TEST_IMAGE; here, from the derived image.
    local TEST_IMAGE="$_image"
    start_file_box "shtest-tty-$$"
}

file_teardown() {
    stop_file_box
    [ -f "$FILE_SCRATCH/image" ] || return 0
    "$AGENT_VM" image delete "$(/bin/cat "$FILE_SCRATCH/image")"
}

# on_terminal <input script> <command...>: runs the command on a new local terminal (script),
# feeding it the output of the input script (a shell snippet run with sh -c); OUT, STATUS.
on_terminal() {
    local _input="$1"
    shift
    # PIPESTATUS must be read inside the substitution: outside it describes the assignment.
    OUT="$( { /bin/sh -c "$_input" | /usr/bin/script -q /dev/null "$@" 2>&1; printf '%s' "${PIPESTATUS[1]}" > "$SCRATCH/.terminal-status"; } \
        | /usr/bin/tr -d '\r')"
    STATUS="$(/bin/cat "$SCRATCH/.terminal-status")"
    printf '$ (on a terminal) %s\n%s\n[status %s]\n' "$*" "$OUT" "$STATUS"
}

test_the_program_gets_a_terminal_of_this_size() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    on_terminal ':' /bin/sh -c "stty rows 30 cols 100; \"$AGENT_VM\" exec -t --box $BOX -- /bin/sh -c 'tty; stty size; echo TERM=\$TERM'"
    assert_status 0 || return 1
    assert_out_contains "/dev/ttys" || return 1
    assert_out_contains "30 100" || return 1
    assert_out_contains "TERM=xterm-256color" || return 1
}

test_control_c_reaches_the_program() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    on_terminal "/bin/sleep 4; printf '\\003'" "$AGENT_VM" exec -t --box "$BOX" -- /bin/sleep 60
    assert_status 130 || return 1
}

# Raw mode ends with the program, whichever way exec ends: the program's own exit, and a closed
# output (exec's EPIPE exit).
test_the_local_terminal_is_restored() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    on_terminal ':' /bin/sh -c "/bin/stty -g > '$SCRATCH/tty-before'; \"$AGENT_VM\" exec -t --box $BOX -- /bin/sh -c 'exit 5'; echo exec-status=\$?; /bin/stty -g > '$SCRATCH/tty-after'; \"$AGENT_VM\" exec -t --box $BOX -- /usr/bin/yes | /usr/bin/head -1 > /dev/null; /bin/stty -g > '$SCRATCH/tty-piped'"
    assert_status 0 || return 1
    assert_out_contains "exec-status=5" || return 1
    local _before="$(/bin/cat "$SCRATCH/tty-before")"
    local _after="$(/bin/cat "$SCRATCH/tty-after")"
    local _piped="$(/bin/cat "$SCRATCH/tty-piped")"
    assert_contains "$_before" ":" "stty -g before exec" || return 1
    assert_eq "$_after" "$_before" "terminal settings after exec -t" || return 1
    assert_eq "$_piped" "$_before" "terminal settings after exec -t into a closed pipe" || return 1
}

test_box_shell_is_a_login_shell() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    on_terminal "/bin/sleep 4; printf 'echo shell-\$((6*7)) \$(whoami)\\r'; /bin/sleep 1; printf 'exit 3\\r'" "$AGENT_VM" box shell "$BOX"
    assert_status 3 || return 1
    assert_out_contains "shell-42 agent" || return 1
    on_terminal "/bin/sleep 4; printf 'echo I am \$(whoami)\\r'; /bin/sleep 1; printf 'exit\\r'" "$AGENT_VM" box shell "$BOX" --user root
    assert_status 0 || return 1
    assert_out_contains "I am root" || return 1
}

test_the_exec_log_records_runs_but_not_environments() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _secret="sk-shtest-$$-$RANDOM"
    run_avm exec --box "$BOX" --env "LOGTEST_KEY=$_secret" -- /bin/sh -c 'exit 7'
    assert_status 7 || return 1
    run_avm box execlog "$BOX" --last 1 --json
    assert_status 0 || return 1
    assert_json 0.status 7 || return 1
    assert_json 0.argv.2 "exit 7" || return 1
    assert_json 0.user agent || return 1
    run_avm box execlog "$BOX"
    assert_out_contains "status 7" || return 1
    assert_out_contains "/bin/sh -c 'exit 7'" || return 1
    local _log="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX/exec.jsonl"
    assert_exists "$_log" || return 1
    local _found
    _found="$(/usr/bin/grep -c -e "$_secret" "$_log")"
    assert_eq "$_found" "0" "lines holding the value" || return 1
}

# The derived image already has this agent-vm's daemon: an update changes nothing.
test_update_guest_leaves_a_current_image_alone() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _image
    _image="$(/bin/cat "$FILE_SCRATCH/image")"
    run_avm image update-guest "$_image"
    assert_status 0 || return 1
    assert_out_contains "agent-vm-guest is already this agent-vm's" || return 1
    run_avm image list --json
    assert_contains "$OUT" "\"terminal\"" "image list" || return 1
}

# A shell at its prompt ignores SIGTERM; agent-vm itself ends the session instead, as ssh does,
# and the box hangs the shell up. agent-vm runs in the background with the terminal as stdin (no
# job control, so it stays in the foreground group) and its own PID in a file.
test_sigterm_ends_a_box_shell() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _pidfile="$SCRATCH/shell.pid"
    # The input stays open: at its end script types Control-D, which would log the shell out.
    on_terminal '/bin/sleep 12' /bin/sh -c "/bin/stty -g > '$SCRATCH/tty-before'; \"$AGENT_VM\" box shell $BOX < /dev/tty & echo \$! > '$_pidfile'; wait \$!; echo shell-status=\$?; /bin/stty -g > '$SCRATCH/tty-after'" &
    local _runner=$!
    local _waited=0
    while [ ! -s "$_pidfile" ] && [ "$_waited" -lt 50 ]; do
        /bin/sleep 0.2
        _waited=$((_waited + 1))
    done
    /bin/sleep 4
    local _pid
    _pid="$(/bin/cat "$_pidfile" 2>/dev/null)"
    [ -n "$_pid" ] || { fail "agent-vm did not start"; return 1; }
    kill -TERM "$_pid"
    wait "$_runner"
    local _log="$SCRATCH/log"
    local _status_line
    _status_line="$(/usr/bin/grep -a -o 'shell-status=[0-9]*' "$_log" | /usr/bin/tail -1)"
    assert_eq "$_status_line" "shell-status=143" "agent-vm's status" || return 1
    assert_eq "$(/bin/cat "$SCRATCH/tty-after")" "$(/bin/cat "$SCRATCH/tty-before")" "terminal settings" || return 1
}

# The screen lock and screen saver are per machine, so a box gets them turned off when its screen
# is first shown (box view); display sleep stays off from the image.
test_the_desktop_never_locks() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box view "$BOX"
    case "$ERR" in
        *"outside a login session"*)
            skip "the supervisor runs outside a login session"
            return 0
            ;;
    esac
    /bin/sleep 8
    run_avm exec --box "$BOX" --user root -- /bin/sh -c 'uid=$(/usr/bin/id -u agent); /bin/launchctl asuser $uid /usr/bin/sudo -u agent /usr/sbin/sysadminctl -screenLock status 2>&1; /usr/bin/pmset -g | /usr/bin/grep displaysleep'
    assert_status 0 || return 1
    assert_out_contains "screenLock is off" || return 1
    assert_out_contains "displaysleep         0" || return 1
}

# Full Disk Access is probed while building and recorded; the derived image has none yet.
test_images_record_full_disk_access() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _image
    _image="$(/bin/cat "$FILE_SCRATCH/image")"
    run_avm image list
    assert_out_contains "agent-vm-guest has no Full Disk Access" || return 1
    assert_out_contains "\`agent-vm image setup $_image\`" || return 1
}

# box view --type and --type-password: keys reach the focused field in the guest (a script
# reading a line in the guest's Terminal), Shift included. Skipped outside a login session.
test_typing_into_the_screen() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box view "$BOX" --interactive
    case "$ERR" in
        *"outside a login session"*)
            skip "the supervisor runs outside a login session"
            return 0
            ;;
    esac
    assert_status 0 || return 1
    local _reader='rm -f /tmp/started /tmp/typed; printf "#!/bin/sh\necho started > /tmp/started\nIFS= read -r line\nprintf \"%%s\" \"\$line\" > /tmp/typed\n" > /tmp/reader.command; chmod 755 /tmp/reader.command'
    local _text _expected
    for _text in 'Typed-OK_42 x/y.z >AB' '<password>'; do
        run_avm exec --box "$BOX" -- /bin/sh -c "$_reader"
        run_avm exec --box "$BOX" --user root -- /bin/sh -c 'uid=$(/usr/bin/id -u agent); /bin/launchctl asuser $uid /usr/bin/sudo -u agent /usr/bin/open /tmp/reader.command'
        local _waited=0
        while [ "$_waited" -lt 30 ]; do
            /bin/sleep 1
            _waited=$((_waited + 1))
            run_avm exec --box "$BOX" -- /bin/test -f /tmp/started
            [ "$STATUS" -eq 0 ] && break
        done
        /bin/sleep 1
        if [ "$_text" = "<password>" ]; then
            run_avm box view "$BOX" --type-password
            assert_status 0 || return 1
            run_avm box view "$BOX" --type $'\r'
            _expected="$(/bin/cat "${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX/Password")"
        else
            run_avm box view "$BOX" --type "$_text"$'\r'
            _expected="$_text"
        fi
        assert_status 0 || return 1
        /bin/sleep 2
        run_avm exec --box "$BOX" -- /bin/cat /tmp/typed
        [ "$OUT" = "$_expected" ] || { fail "the guest read something else than was typed (${#OUT} characters, ${#_expected} expected)"; return 1; }
    done
}
