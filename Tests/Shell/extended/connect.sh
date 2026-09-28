#!/bin/bash
#
# Tests/Shell/extended/connect.sh - agent-vm connect, as avm, on a real box: a command in the
# shared folder with its status passed back, a stopped box started (and left running, with no
# owner), the terminal restored, a box busy with another folder refused, and the snapshot of a
# read-write share with its report afterwards: keep, undo, no changes, read only, and a second
# session on a folder. One box from $TEST_IMAGE for the file; script(1) provides the terminal
# (on_terminal). Sessions the tests make are discarded at their end.

# answer_when_done <file> <keys>: on_terminal input that waits for <file>, which the program in
# the box writes last, then types <keys> once a second: keys typed while the session still runs
# would go to the box, not to the question after it.
answer_when_done() {
    printf 'n=0; while [ ! -e %s ] && [ $n -lt 240 ]; do /bin/sleep 0.5; n=$((n+1)); done; /bin/sleep 2; i=0; while [ $i -lt 30 ]; do printf %s; /bin/sleep 1; i=$((i+1)); done' "'$1'" "'$2'"
}

# session_id: the session named in $OUT's "Snapshot of ... taken (session <id>)" line.
session_id() {
    printf '%s\n' "$OUT" | /usr/bin/sed -n 's/^Snapshot of .* taken (session \([^)]*\))$/\1/p' | /usr/bin/head -n 1
}

# session_state <id>: the state in the session's record.
session_state() {
    local _root="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}"
    /usr/bin/plutil -extract state raw -o - "$_root/Sessions/$1/session.json" 2>/dev/null
}

# changing_project <folder>: a project whose work.sh, run in the box, adds new.txt and twelve
# executable files (each flagged), then .done.
changing_project() {
    make_project "$1"
    printf '%s\n' 'cd "$(/usr/bin/dirname "$0")" || exit 1' 'echo x > new.txt' \
        'for n in 1 2 3 4 5 6 7 8 9 10 11 12; do printf "#!/bin/sh\n" > hook$n; /bin/chmod +x hook$n; done' \
        'touch .done' > "$1/work.sh"
}

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
    # Snapshotted, and with nothing changed, discarded.
    assert_out_contains "No changes in" || return 1
    local _id
    _id="$(session_id)"
    assert_eq "$(session_state "$_id")" "discarded" "the session" || return 1
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
    # The box started in file_setup, so its last boot time is known.
    assert_out_contains "(usually about " || return 1
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
    assert_out_contains "no end recorded in agent-vm box execlog $BOX" || return 1
}

test_connect_keeps_changes() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    changing_project "$SCRATCH/project"
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    on_terminal "$(answer_when_done "$_project/.done" 'k\n')" "$SCRATCH/avm" "$BOX" --project "$_project" -- /bin/sh "$_project/work.sh"
    local _id
    _id="$(session_id)"
    local _state
    _state="$(session_state "$_id")"
    "$AGENT_VM" session discard "$_id" > /dev/null 2>&1
    assert_status 0 || return 1
    assert_out_contains "review first: 12 medium" || return 1
    assert_out_contains "... and 2 more flagged; r shows every change" || return 1
    assert_out_contains "Kept. Undo later with: agent-vm session undo $_id" || return 1
    assert_exists "$_project/new.txt" || return 1
    assert_eq "$_state" "ended" "the session" || return 1
}

test_connect_undoes_changes() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    changing_project "$SCRATCH/project"
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    on_terminal "$(answer_when_done "$_project/.done" 'u\n')" "$SCRATCH/avm" "$BOX" --project "$_project" -- /bin/sh "$_project/work.sh"
    local _id
    _id="$(session_id)"
    local _state
    _state="$(session_state "$_id")"
    "$AGENT_VM" session discard "$_id" > /dev/null 2>&1
    assert_status 0 || return 1
    assert_out_contains "Restored $_project to its state at" || return 1
    assert_missing "$_project/new.txt" || return 1
    assert_missing "$_project/hook1" || return 1
    assert_exists "$_project/README.md" || return 1
    assert_eq "$_state" "undone" "the session" || return 1
}

test_connect_read_only() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    make_project "$SCRATCH/project"
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    on_terminal ':' "$SCRATCH/avm" "$BOX" --read-only --project "$_project" -- /usr/bin/touch "$_project/x"
    assert_status 1 || return 1
    assert_out_contains "Sharing $_project (read only)" || return 1
    assert_not_contains "$OUT" "Snapshot of" "the output" || return 1
    assert_missing "$_project/x" || return 1
}

test_connect_second_session_goes_on_without_a_snapshot() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    make_project "$SCRATCH/project"
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    run_avm session start --project "$_project" --json
    assert_status 0 || return 1
    local _first
    _first="$(json_value id)"
    # Enter takes the default: go on without a new snapshot.
    on_terminal "printf '\\n'" "$SCRATCH/avm" "$BOX" --project "$_project" -- /usr/bin/true
    local _status="$STATUS"
    "$AGENT_VM" session end "$_first" > /dev/null 2>&1
    "$AGENT_VM" session discard "$_first" > /dev/null 2>&1
    assert_eq "$_status" "0" "avm's status" || return 1
    assert_out_contains "Session $_first is already active for" || return 1
    assert_not_contains "$OUT" "Snapshot of" "the output" || return 1
    assert_not_contains "$OUT" "No changes in" "the output" || return 1
}
