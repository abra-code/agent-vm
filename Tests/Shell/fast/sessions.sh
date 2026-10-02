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

    run_avm session report "$SESSION"
    assert_status 0 || return 1
    assert_printable "$OUT" "the report" || return 1
    # The line end inside a name does not start a line: no line begins with the forged text.
    local _forged
    _forged="$(printf '%s\n' "$OUT" | /usr/bin/grep -c '^HIGH   D also-forged')"
    assert_eq "$_forged" "0" "lines forged by a file name" || return 1
    assert_out_contains "zz?[1A?[2K?HIGH   A forged" || return 1

    # JSON keeps the names as they are, escaped as JSON does.
    run_avm session report "$SESSION" --json
    assert_status 0 || return 1
    assert_printable "$OUT" "the JSON report" || return 1
    assert_out_contains '\u001b[1A' || return 1
}
