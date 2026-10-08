#!/bin/bash
#
# Tests/Shell/fast/sessions.sh - Live-mode sessions end to end through the CLI: snapshot, what
# an agent might do, the change report with its flags, undo, discard. No virtual machine.

# start_session <project>: starts a session and sets SESSION to its id.
start_session() {
    run_avm session start --project "$1" --json
    assert_status 0 || return 1
    SESSION="$(json_value id)"
    [ -n "$SESSION" ] || fail "no session id in: $OUT"
}

test_report_flags_what_would_run_later_and_undo_restores() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1

    # What a hostile agent might leave behind.
    printf '#!/bin/sh\ncurl evil\n' > "$_project/.git/hooks/pre-commit"
    /bin/chmod 755 "$_project/.git/hooks/pre-commit"
    printf '{"mcpServers": {}}\n' > "$_project/.mcp.json"
    /bin/ln -s /Users "$_project/escape"
    printf 'changed\n' > "$_project/README.md"
    /bin/rm "$_project/build.sh"
    /bin/mkdir -p "$_project/node_modules/pkg"
    printf 'x' > "$_project/node_modules/pkg/index.js"

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "HIGH" || return 1
    assert_out_contains ".git/hooks/pre-commit" || return 1
    assert_out_contains ".mcp.json" || return 1
    assert_out_contains "escape -> /Users" || return 1
    assert_out_contains "node_modules/ (2 entries inside)" || return 1

    run_avm session report "$SESSION" --fail-on high
    assert_status 2 || return 1

    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    assert_json summary.deleted 1 || return 1
    assert_json summary.modified 1 || return 1

    run_avm session undo "$SESSION"
    assert_status 0 || return 1
    assert_eq "$(/bin/cat "$_project/README.md")" "hello" "README after undo" || return 1
    assert_exists "$_project/build.sh" || return 1
    assert_missing "$_project/.git/hooks/pre-commit" || return 1
    assert_missing "$_project/escape" || return 1
    assert_missing "$_project/node_modules" || return 1

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "no changes" || return 1

    run_avm session list --json
    assert_status 0 || return 1
    assert_json 0.state undone || return 1

    run_avm session discard "$SESSION"
    assert_status 0 || return 1
    run_avm session list --json
    assert_json 0.state discarded || return 1
}

test_undo_by_path_and_discard_by_age() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1
    printf 'changed\n' > "$_project/README.md"
    /bin/rm "$_project/build.sh"
    printf 'added\n' > "$_project/notes.txt"

    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    local _snapshot
    _snapshot="$(json_value snapshotPath)"
    assert_eq "$(/bin/cat "$_snapshot/README.md")" "hello" "the snapshot at snapshotPath" || return 1

    # A path that did not change is refused before anything moves.
    run_avm session undo "$SESSION" --path README.md --path Sources/App/main.swift
    assert_status 1 || return 1
    assert_err_contains "cannot undo Sources/App/main.swift on its own: it did not change" || return 1
    assert_eq "$(/bin/cat "$_project/README.md")" "changed" "README after a refused undo" || return 1
    run_avm session undo "$SESSION" --path README.md --whole-tree
    assert_status 64 || return 1

    run_avm session undo "$SESSION" --path README.md --path "$_project/build.sh" --json
    assert_status 0 || return 1
    assert_json session.state active || return 1
    assert_json session.snapshotPath "$_snapshot" || return 1
    assert_json restore.remaining 0 || return 1
    assert_eq "$(/bin/cat "$_project/README.md")" "hello" "README after undo --path" || return 1
    assert_exists "$_project/build.sh" || return 1
    assert_exists "$_project/notes.txt" || return 1

    run_avm session undo "$SESSION" --path notes.txt
    assert_status 0 || return 1
    assert_out_contains "nothing else changed" || return 1
    assert_missing "$_project/notes.txt" || return 1

    run_avm session list --json
    assert_json 0.state undone || return 1
    assert_json 0.snapshotPath "$_snapshot" || return 1

    # By age: an active session stays, an undone one goes once it is old enough.
    start_session "$_project" || return 1
    local _active="$SESSION"
    run_avm session discard --older-than 1
    assert_status 0 || return 1
    assert_out_contains "No ended or undone sessions that old." || return 1
    run_avm session discard --older-than 0 --json
    assert_status 0 || return 1
    assert_json 0.state discarded || return 1
    assert_json 1 "" || return 1
    assert_missing "$_snapshot" || return 1
    run_avm session list --json
    assert_json 1.id "$_active" || return 1
    assert_json 1.state active || return 1
    run_avm session discard
    assert_status 64 || return 1
    run_avm session discard "$_active" --older-than 0
    assert_status 64 || return 1
}

test_whole_tree_undo_swaps_the_folder() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1
    printf 'agent was here\n' > "$_project/NEW.txt"
    run_avm session undo "$SESSION" --whole-tree
    assert_status 0 || return 1
    assert_missing "$_project/NEW.txt" || return 1
    assert_exists "$_project/README.md" || return 1
}

test_undo_is_not_blocked_by_a_locked_tree() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1
    printf 'x' > "$_project/locked.txt"
    /usr/bin/chflags uchg "$_project/locked.txt"
    /bin/chmod 555 "$_project/Sources"
    run_avm session undo "$SESSION"
    assert_status 0 || return 1
    assert_missing "$_project/locked.txt" || return 1
    run_avm session discard "$SESSION"
    assert_status 0 || return 1
    # The agent's version stays in the session folder until discard; clean up the flags.
    /bin/chmod -R u+w "$_project" 2>/dev/null
}

test_what_a_session_left_does_not_stop_the_next_one() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1
    local _first="$SESSION"

    # A file nobody can read, and a git hook under a spelling the volume takes for `.git`.
    printf 'secret\n' > "$_project/closed.txt"
    /bin/chmod 000 "$_project/closed.txt"
    /bin/mkdir -p "$_project/sub/.GIT/hooks"
    printf '#!/bin/sh\n' > "$_project/sub/.GIT/hooks/pre-commit"

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "HIGH" || return 1
    assert_out_contains "sub/.GIT/hooks/pre-commit" || return 1
    run_avm session end "$SESSION"
    assert_status 0 || return 1

    # The changes are kept, and the next session snapshots them as they are.
    start_session "$_project" || return 1
    local _mode="$(/usr/bin/stat -f '%Lp' "$_project/closed.txt")"
    assert_eq "$_mode" "0" "mode of the unreadable file after the snapshot" || return 1
    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "no changes" || return 1
    run_avm session discard "$SESSION"
    assert_status 0 || return 1
    run_avm session discard "$_first"
    assert_status 0 || return 1
    /bin/chmod 600 "$_project/closed.txt"
}

test_one_active_session_per_project() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1
    run_avm session start --project "$_project"
    assert_status 1 || return 1
    assert_err_contains "is still active" || return 1
    run_avm session end "$SESSION"
    assert_status 0 || return 1
    run_avm session start --project "$_project"
    assert_status 0 || return 1
}

test_sessions_refuse_the_home_folder_and_its_aliases() {
    run_avm session start --project "$HOME"
    assert_status 1 || return 1
    assert_err_contains "home folder" || return 1
    run_avm session start --project "/System/Volumes/Data$HOME"
    assert_status 1 || return 1
    assert_err_contains "home folder" || return 1
    run_avm session start --project /
    assert_status 1 || return 1
}

test_unknown_session_ids_are_explained() {
    run_avm session report 20260101-000000-abcd
    assert_status 1 || return 1
    assert_err_contains "no session" || return 1
    run_avm session report not-an-id
    assert_status 1 || return 1
    assert_err_contains "is not a session id" || return 1
}

test_names_an_agent_chose_cannot_act_on_the_terminal() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    start_session "$_project" || return 1

    # A name that erases the line above it and writes its own, one with a line end that would
    # start a forged report line, and a link whose target does the same.
    local _escape
    _escape="$(printf '\033')"
    local _return
    _return="$(printf '\r')"
    local _newline
    _newline="$(printf '\nx')"
    _newline="${_newline%x}"
    printf 'x' > "$_project/zz${_escape}[1A${_escape}[2K${_return}HIGH   A forged"
    printf 'x' > "$_project/.envrc${_newline}HIGH   D also-forged"
    /bin/ln -s "/etc/passwd${_escape}]0;title${_return}" "$_project/link"
    # A link whose target holds a line end, and a hook (a flagged name, so its reason is printed
    # too) in a folder whose name holds one.
    /bin/ln -s "/etc/passwd${_newline}HIGH   D forged-by-target" "$_project/link2"
    /bin/mkdir -p "$_project/sub${_newline}HIGH   D forged-by-folder/.git/hooks"
    printf '#!/bin/sh\n' > "$_project/sub${_newline}HIGH   D forged-by-folder/.git/hooks/pre-commit"

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_printable "$OUT" "the report" || return 1
    # The line end inside a name does not start a line: no line begins with the forged text.
    local _forged
    _forged="$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^HIGH   D also-forged')"
    assert_eq "$_forged" "0" "lines forged by a file name" || return 1
    _forged="$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^HIGH   D forged-by')"
    assert_eq "$_forged" "0" "lines forged by a link target or a folder name" || return 1
    assert_out_contains "git hook" || return 1
    assert_out_contains "zz?[1A?[2K?HIGH   A forged" || return 1

    # JSON keeps the names as they are, escaped as JSON does.
    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    assert_printable "$OUT" "the JSON report" || return 1
    assert_out_contains '\u001b[1A' || return 1
}

# session report shows, after the changes, the programs started for the project during the
# session and the network of their box over that time; the two logs take --session; and a box
# deleted since is read from its kept logs.
test_report_shows_the_sessions_programs_and_network() {
    local _project="$SCRATCH/project"
    make_project "$_project"
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    local _box="$AGENT_VM_HOME/Boxes/b1"
    # What the box logged the day before is not of the session.
    printf '%s\n' \
        '{"time":"2026-10-01T10:00:00Z","timeMilliseconds":0,"method":"CONNECT","host":"earlier.example","port":443,"decision":"allowed","rule":"public","id":"old","bytesUp":9000,"bytesDown":1}' \
        > "$_box/network-allowed.jsonl"
    printf '%s\n' '{"id":"p0","event":"start","time":"2026-10-01T10:00:00Z","argv":["/bin/echo","before"],"user":"agent"}' > "$_box/exec.jsonl"
    start_session "$_project" || return 1
    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_not_contains "$OUT" "programs in" "a session without programs" || return 1

    # What `agent-vm exec --project` writes when it starts a program during the session.
    local _now
    _now="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    local _path
    _path="$(cd "$_project" && /bin/pwd -P)"
    printf '%s\n' \
        "{\"id\":\"p1\",\"event\":\"start\",\"time\":\"$_now\",\"argv\":[\"/usr/bin/agent\",\"--go\"],\"user\":\"agent\",\"project\":\"$_path\",\"session\":\"$SESSION\"}" \
        "{\"id\":\"p1\",\"event\":\"end\",\"time\":\"$_now\",\"status\":0,\"seconds\":2.5}" \
        "{\"id\":\"p2\",\"event\":\"start\",\"time\":\"$_now\",\"argv\":[\"/bin/ls\"],\"user\":\"agent\"}" \
        >> "$_box/exec.jsonl"
    printf '%s\n' "{\"box\":\"b1\",\"exec\":\"p1\",\"time\":\"$_now\"}" > "$AGENT_VM_HOME/Sessions/$SESSION/runs.jsonl"
    printf '%s\n' \
        "{\"time\":\"$_now\",\"timeMilliseconds\":0,\"method\":\"CONNECT\",\"host\":\"api.example\",\"port\":443,\"decision\":\"allowed\",\"rule\":\"public\",\"id\":\"a\",\"bytesUp\":2000000,\"bytesDown\":300}" \
        >> "$_box/network-allowed.jsonl"
    printf '%s\n' \
        "{\"time\":\"$_now\",\"timeMilliseconds\":0,\"method\":\"CONNECT\",\"host\":\"no.example\",\"port\":443,\"decision\":\"denied\",\"reason\":\"not in the allowlist\"}" \
        > "$_box/network.jsonl"
    printf 'changed\n' > "$_project/README.md"
    /bin/sleep 1

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "1 modified" || return 1
    assert_out_contains "programs in box b1: 1" || return 1
    assert_out_contains "status 0  2.5 s  /usr/bin/agent --go" || return 1
    assert_not_contains "$OUT" "/bin/ls" "a program of no session" || return 1
    assert_out_contains "network of box b1 meanwhile: 2 hosts, 1 connection, 2 MB sent, 300 bytes received, 1 refused, 0 failed" || return 1
    assert_out_contains "api.example:443  1 made" || return 1
    assert_out_contains "no.example:443  0 made, 1 refused" || return 1
    assert_not_contains "$OUT" "earlier.example" "a connection from before the session" || return 1
    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    assert_json session "$SESSION" || return 1
    assert_json summary.modified 1 || return 1
    assert_json boxes.0 b1 || return 1
    assert_json programs.0.box b1 || return 1
    assert_json programs.0.program.id p1 || return 1
    assert_json programs.0.program.session "$SESSION" || return 1
    assert_json programs 1 || return 1
    assert_json network.hosts.0.host api.example || return 1
    assert_json network.bytesUp 2000000 || return 1
    assert_json network.refused 1 || return 1
    assert_json activityNotes 0 || return 1

    run_avm box execlog b1 --session "$SESSION" --json
    assert_status 0 || return 1
    assert_json 0.id p1 || return 1
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/jq -r 'length')" "1" "the session's programs" || return 1
    run_avm box netlog b1 --session "$SESSION" --summary --json
    assert_status 0 || return 1
    assert_json bytesUp 2000000 || return 1
    assert_json hosts 2 || return 1
    run_avm box netlog b1 --session nosuch
    assert_status 1 || return 1
    # A --until before the session started leaves nothing, and the error says so instead of
    # blaming a --since nobody gave.
    run_avm box netlog b1 --session "$SESSION" --until 2026-10-02
    assert_status 64 || return 1
    assert_contains "$ERR" "nothing of the session's time" "the error" || return 1
    assert_not_contains "$ERR" "is not after --since" "the error" || return 1

    # The box is deleted: the report reads its kept logs, which name the session.
    run_avm box delete b1 --json
    assert_status 0 || return 1
    local _kept
    _kept="$(json_value keptLogs)"
    assert_contains "$(/bin/cat "$_kept/kept.json")" "$SESSION" "the kept record" || return 1
    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    assert_json programs.0.program.id p1 || return 1
    assert_json network.bytesUp 2000000 || return 1
    run_avm box execlog "$(/usr/bin/basename "$_kept")" --kept --session "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "/usr/bin/agent --go" || return 1
    # With the kept logs removed too, the report says that they are gone.
    run_avm store logs --remove "$(/usr/bin/basename "$_kept")"
    assert_status 0 || return 1
    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_out_contains "note: the logs of box b1 are gone: its programs and connections are not listed" || return 1
}
