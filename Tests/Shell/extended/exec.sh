#!/bin/bash
#
# Tests/Shell/extended/exec.sh - agent-vm exec against a real box: output and input streams,
# exit statuses, signals, environment, accounts, and what happens when the client dies. Also
# box send, which runs its receiving side through exec.

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

test_send_copies_into_downloads() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _name="shtest-send-$$"
    /bin/mkdir -p "$SCRATCH/$_name.app/Contents"
    printf 'plist' > "$SCRATCH/$_name.app/Contents/Info.plist"
    printf 'data' > "$SCRATCH/$_name.txt"
    run_avm box send "$BOX" "$SCRATCH/$_name.txt" "$SCRATCH/$_name.app"
    assert_status 0 || return 1
    assert_out_contains "Sent $_name.txt (1 of 2) to Downloads" || return 1
    # The same name again gets a number, and --json names it.
    run_avm box send "$BOX" "$SCRATCH/$_name.txt" --json
    assert_status 0 || return 1
    assert_out_contains "\"name\" : \"$_name 2.txt\"" || return 1
    assert_err_contains '"step":"send"' || return 1
    run_avm exec --box "$BOX" -- /bin/cat "Downloads/$_name.txt" "Downloads/$_name 2.txt" "Downloads/$_name.app/Contents/Info.plist"
    assert_eq "$OUT" "datadataplist" "what arrived" || return 1
    run_avm exec --box "$BOX" -- /bin/rm -rf "Downloads/$_name.txt" "Downloads/$_name 2.txt" "Downloads/$_name.app"
    assert_status 0 || return 1
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

test_credentials_reach_the_program_and_nowhere_else() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _secret="sk-shtest-$$-$RANDOM"
    printf '# for the agent\nFROM_FILE=file value\nOVERRIDDEN=file\nAVM_SHTEST_KEY\n' > "$SCRATCH/agent.env"
    run_cmd /usr/bin/env AVM_SHTEST_KEY="$_secret" "$AGENT_VM" exec --box "$BOX" \
        --env-file "$SCRATCH/agent.env" --env OVERRIDDEN=flag --env AVM_SHTEST_KEY \
        -- /bin/sh -c 'printf "%s|%s|%s\n" "$AVM_SHTEST_KEY" "$FROM_FILE" "$OVERRIDDEN"'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_secret|file value|flag" "the program's variables" || return 1
    # A pipe, as from a password manager: --env-file <(...).
    run_cmd "$AGENT_VM" exec --box "$BOX" --env-file <(printf 'PIPED=%s\n' "$_secret") -- /bin/sh -c 'printf "%s\n" "$PIPED"'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_secret" "a value from a pipe" || return 1
    # Not in the box's own records on the Mac.
    local _folder="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX"
    assert_exists "$_folder/supervisor.log" || return 1
    local _found
    _found="$(/usr/bin/grep -rl --exclude=Disk.img --exclude=AuxiliaryStorage -e "$_secret" "$_folder" 2>/dev/null)"
    assert_eq "$_found" "" "files in the box folder holding the value" || return 1
}

# Keychain secrets reach the program under their own name or another, win over --env, and are
# recorded nowhere on the Mac. Stored and deleted by this same agent-vm, so macOS never asks.
test_keychain_secrets_reach_the_program() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    export AGENT_VM_SECRET_SERVICE="agent-vm-shtest-$$-$RANDOM"
    trap '"$AGENT_VM" secret delete AVM_SHTEST_SECRET > /dev/null 2>&1' EXIT
    local _secret="sk-kc-$$-$RANDOM"
    run_avm_input "$_secret" secret set AVM_SHTEST_SECRET
    assert_status 0 || return 1
    run_avm exec --box "$BOX" --env AVM_SHTEST_SECRET=from-env --secret AVM_SHTEST_SECRET --secret RENAMED=AVM_SHTEST_SECRET \
        -- /bin/sh -c 'printf "%s|%s\n" "$AVM_SHTEST_SECRET" "$RENAMED"'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_secret|$_secret" "the program's variables" || return 1
    local _folder="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX"
    local _found
    _found="$(/usr/bin/grep -rl --exclude=Disk.img --exclude=AuxiliaryStorage -e "$_secret" "$_folder" 2>/dev/null)"
    assert_eq "$_found" "" "files in the box folder holding the value" || return 1
    run_avm secret delete AVM_SHTEST_SECRET
    assert_status 0 || return 1
}

# A box whose guest daemon predates terminals refuses --tty with a way out, instead of running
# the program without one.
test_a_terminal_needs_a_guest_that_has_one() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _features
    _features="$(/usr/bin/plutil -extract guestFeatures json -o - "$FILE_SCRATCH/box-start.json" 2>/dev/null)"
    case "$_features" in
        *'"terminal"'*)
            skip "the box's agent-vm-guest has terminal support (see terminal.sh)"
            return 0
            ;;
    esac
    OUT="$(/usr/bin/script -q /dev/null "$AGENT_VM" exec -t --box "$BOX" -- /usr/bin/true < /dev/null 2>&1)"
    STATUS=$?
    printf '$ (on a terminal) exec -t\n%s\n[status %s]\n' "$OUT" "$STATUS"
    assert_status 125 || return 1
    assert_out_contains "image update-guest $TEST_IMAGE" || return 1
}

# box view: the supervisor opens a window on this Mac's screen (briefly, during the test; it goes
# with the box at teardown). Skipped when the tests run outside a login session (SSH, CI).
test_box_view_shows_the_screen_and_the_box_keeps_working() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box view "$BOX"
    case "$ERR" in
        *"outside a login session"*)
            skip "the supervisor runs outside a login session"
            return 0
            ;;
    esac
    assert_status 0 || return 1
    assert_out_contains "view only" || return 1
    run_avm box view "$BOX" --interactive
    assert_status 0 || return 1
    local _log="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX/supervisor.log"
    assert_contains "$(/bin/cat "$_log")" "Showing the screen (view only)" "supervisor.log" || return 1
    assert_contains "$(/bin/cat "$_log")" "Showing the screen (interactive)" "supervisor.log" || return 1
    # The supervisor's main actor is not held up by the window.
    run_avm exec --box "$BOX" -- /bin/echo still-running
    assert_status 0 || return 1
    assert_eq "$OUT" "still-running" "exec after box view" || return 1
}
