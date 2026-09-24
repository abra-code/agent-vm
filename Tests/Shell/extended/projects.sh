#!/bin/bash
#
# Tests/Shell/extended/projects.sh - project folders shared into a real box at the same path:
# both directions, read-only shares, nothing written into the project by the guest's volume
# housekeeping, switching projects, and refusals.

file_setup() {
    start_file_box "shtest-proj-$$"
}

file_teardown() {
    stop_file_box
}

test_the_project_has_the_same_path_both_ways() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/project"
    make_project "$_project"
    run_avm exec --box "$BOX" --project "$_project" -- /bin/sh -c '/bin/pwd -P; cat README.md; echo from-box > from-box.txt'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_project"$'\nhello' "path and contents" || return 1
    assert_eq "$(/bin/cat "$_project/from-box.txt")" "from-box" "file written in the box" || return 1
    assert_eq "$(/usr/bin/stat -f %Su "$_project/from-box.txt")" "$(/usr/bin/id -un)" "owner on the Mac" || return 1
    assert_missing "$_project/.fseventsd" || return 1
    assert_missing "$_project/.Trashes" || return 1
}

test_read_only_shares_refuse_writes() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/project"
    make_project "$_project"
    run_avm exec --box "$BOX" --project "$_project" --read-only -- /bin/sh -c 'cat README.md && echo x > new.txt'
    assert_eq "$STATUS" "1" "write to a read-only share" || return 1
    assert_out_contains "hello" || return 1
    assert_missing "$_project/new.txt" || return 1
}

test_switching_waits_for_programs_using_the_project() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _first="$SCRATCH/first"
    local _second="$SCRATCH/second"
    make_project "$_first"
    make_project "$_second"
    "$AGENT_VM" exec --box "$BOX" --project "$_first" -- /bin/sleep 20 &
    local _pid=$!
    /bin/sleep 5
    run_avm exec --box "$BOX" --project "$_second" -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "is running programs on $_first" || return 1
    kill -INT "$_pid"
    wait "$_pid" 2>/dev/null
    run_avm exec --box "$BOX" --project "$_second" -- /bin/pwd -P
    assert_status 0 || return 1
    assert_eq "$OUT" "$_second" "switched project" || return 1
}

test_sensitive_folders_are_refused() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" --project "$HOME/Library/Caches" -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "~/Library" || return 1
    run_avm exec --box "$BOX" --project "$HOME" -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "home folder" || return 1
}
