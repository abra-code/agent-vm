#!/bin/bash
#
# Tests/Shell/extended/linux-projects.sh - project folders shared into a real Linux box at the
# same path: both directions, git as the first command (the share reports a file as owned by
# whoever asks, and remembers it for a second), read-only shares, switching, refusals, and a
# session's report and undo. From the ready Linux image $AGENT_VM_TEST_LINUX_IMAGE; without it
# every test is skipped.

file_setup() {
    start_linux_file_box "shtest-lproj-$$"
}

file_teardown() {
    stop_file_box
}

# make_repository <folder>: a git repository with one commit, and a second one in a subfolder.
make_repository() {
    /bin/mkdir -p "$1/nested"
    printf 'hello\n' > "$1/README.md"
    printf '#!/bin/sh\necho private script ran\n' > "$1/private.sh"
    /bin/chmod 700 "$1/private.sh"
    /usr/bin/git -C "$1" init -q . || return 1
    /usr/bin/git -C "$1" add README.md private.sh || return 1
    /usr/bin/git -C "$1" -c user.email=test@example.com -c user.name=Test commit -q -m one || return 1
    printf 'inner\n' > "$1/nested/inner.txt"
    /usr/bin/git -C "$1/nested" init -q . || return 1
}

test_the_project_is_at_its_own_path() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/project"
    make_project "$_project"
    run_avm exec --box "$BOX" --project "$_project" -- /bin/sh -c 'pwd -P; cat README.md; echo from-box > from-box.txt; id -un; stat -c %U README.md'
    assert_status 0 || return 1
    assert_eq "$OUT" "$_project"$'\nhello\nagent\nagent' "path, contents and owner in the box" || return 1
    assert_eq "$(/bin/cat "$_project/from-box.txt")" "from-box" "file written in the box" || return 1
    assert_eq "$(/usr/bin/stat -f %Su "$_project/from-box.txt")" "$(/usr/bin/id -un)" "owner on the Mac" || return 1
    # The folder itself is mounted, with nothing of root's and no device files honored.
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/findmnt -n -o FSTYPE,SOURCE,OPTIONS "$_project"
    assert_status 0 || return 1
    assert_out_contains "virtiofs" || return 1
    assert_out_contains "agent-vm-project" || return 1
    assert_out_contains "nosuid,nodev" || return 1
    # A file edited on the Mac is read back in the box at once.
    printf 'changed on the Mac\n' > "$_project/README.md"
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/cat README.md
    assert_eq "$OUT" "changed on the Mac" "the Mac's edit, in the box" || return 1
}

# git refuses a repository whose owner is someone else. Right after the share, and right after
# root looked at the project, the box user's git must still work, in the project and in a
# repository under it.
test_git_status_is_the_first_command() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/repository"
    make_repository "$_project" || { fail "cannot make the test repository"; return 1; }
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/git status --short
    assert_status 0 || return 1
    assert_not_contains "$ERR" "dubious ownership" "git's first words" || return 1
    assert_out_contains "nested/" || return 1
    local _round
    for _round in 1 2 3; do
        run_avm exec --box "$BOX" --user root --project "$_project" -- /usr/bin/ls -la .
        assert_status 0 || return 1
        run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/git status --short
        assert_status 0 || return 1
        assert_not_contains "$ERR" "dubious ownership" "git right after root's look" || return 1
        run_avm exec --box "$BOX" --project "$_project" --cwd "$_project/nested" -- /usr/bin/git status --short
        assert_status 0 || return 1
        assert_out_contains "inner.txt" || return 1
    done
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/git log --oneline
    assert_status 0 || return 1
    assert_out_contains "one" || return 1
    # Only the project is a safe place for git, not the whole disk.
    run_avm exec --box "$BOX" --user root -- /usr/bin/cat /etc/agent-vm/gitconfig
    assert_out_contains "directory = $_project" || return 1
    assert_out_contains "directory = $_project/*" || return 1
    assert_eq "$(printf '%s\n' "$OUT" | /usr/bin/grep -c 'directory = ')" "2" "safe places named to git" || return 1
}

# The same folder unmounted and mounted again within a second, read-only and back: git and
# chmod work at once each time.
test_the_same_project_again_read_only() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/repository"
    make_repository "$_project" || { fail "cannot make the test repository"; return 1; }
    local _round
    for _round in 1 2 3; do
        run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/true
        assert_status 0 || return 1
        run_avm exec --box "$BOX" --project "$_project" --read-only -- /usr/bin/git status --short
        assert_status 0 || return 1
        run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/chmod 600 README.md
        assert_status 0 || return 1
        run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/chmod 644 README.md
        assert_status 0 || return 1
    done
    assert_eq "$(/usr/bin/stat -f %Lp "$_project/README.md")" "644" "the mode on the Mac" || return 1
}

# The first command on a fresh share is one that only the file's owner may do: it fails if
# anything looked at the project as root while it was being shared (git above would not show
# that, since it is told the project is safe).
test_chmod_and_a_private_script_right_after_the_share() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/fresh"
    make_repository "$_project" || { fail "cannot make the test repository"; return 1; }
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/chmod 600 README.md
    assert_status 0 || return 1
    assert_eq "$(/usr/bin/stat -f %Lp "$_project/README.md")" "600" "the mode on the Mac" || return 1
    # Mode 700: only its owner runs it, and in the box the owner is the box user.
    run_avm exec --box "$BOX" --project "$_project" -- ./private.sh
    assert_status 0 || return 1
    assert_eq "$OUT" "private script ran" "a script only its owner may run" || return 1
}

test_read_only() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/project"
    make_project "$_project"
    run_avm exec --box "$BOX" --project "$_project" --read-only -- /bin/sh -c 'cat README.md && echo x > new.txt'
    [ "$STATUS" -ne 0 ] || { fail "a write to a read-only share succeeded"; return 1; }
    assert_out_contains "hello" || return 1
    assert_missing "$_project/new.txt" || return 1
    run_avm exec --box "$BOX" --user root --project "$_project" --read-only -- /usr/bin/touch root-made.txt
    [ "$STATUS" -ne 0 ] || { fail "root wrote to a read-only share"; return 1; }
    assert_missing "$_project/root-made.txt" || return 1
    run_avm exec --box "$BOX" --project "$_project" --read-only -- /usr/bin/findmnt -n -o OPTIONS "$_project"
    assert_out_contains "ro," || return 1
}

test_switching_projects_and_a_busy_one() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _first="$SCRATCH/first"
    local _second="$SCRATCH/second"
    make_project "$_first"
    make_project "$_second"
    "$AGENT_VM" exec --box "$BOX" --project "$_first" -- /usr/bin/sleep 20 &
    local _pid=$!
    /bin/sleep 4
    run_avm exec --box "$BOX" --project "$_second" -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "is running programs on $_first" || return 1
    kill -INT "$_pid"
    wait "$_pid" 2>/dev/null
    run_avm exec --box "$BOX" --project "$_second" -- /usr/bin/pwd -P
    assert_status 0 || return 1
    assert_eq "$OUT" "$_second" "switched project" || return 1
    # The first project is no longer there: its path is an empty folder of the box's own.
    run_avm exec --box "$BOX" -- /usr/bin/ls -A "$_first"
    assert_eq "$OUT" "" "the first project's path after the switch" || return 1
    run_avm exec --box "$BOX" --user root -- /usr/bin/cat /etc/agent-vm/gitconfig
    assert_not_contains "$OUT" "$_first" "git's safe places after the switch" || return 1
}

test_a_path_that_holds_something_is_refused() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/occupied"
    make_project "$_project"
    # The same path in the box, with a file of the box's own in it.
    run_avm exec --box "$BOX" --user root -- /bin/sh -c 'mkdir -p "$1" && echo mine > "$1/box-file"' sh "$_project"
    assert_status 0 || return 1
    run_avm exec --box "$BOX" --project "$_project" -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "$_project in the box already holds $_project/box-file, which the share would hide; share a folder whose path is new or holds only folders in the box" || return 1
    # Nothing was mounted over it, and another project still works.
    run_avm exec --box "$BOX" -- /usr/bin/cat "$_project/box-file"
    assert_eq "$OUT" "mine" "the box's own file" || return 1
    make_project "$SCRATCH/other"
    run_avm exec --box "$BOX" --project "$SCRATCH/other" -- /usr/bin/cat README.md
    assert_eq "$OUT" "hello" "another project after the refusal" || return 1
}

# A project inside one that was shared before, and the outer one again: the folders the first
# mount left in the box hold nothing, so they are not in the way.
test_a_project_inside_another() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _outer="$SCRATCH/outer"
    make_project "$_outer"
    make_project "$_outer/inner"
    run_avm exec --box "$BOX" --project "$_outer/inner" -- /usr/bin/pwd -P
    assert_status 0 || return 1
    assert_eq "$OUT" "$_outer/inner" "the inner project" || return 1
    run_avm exec --box "$BOX" --project "$_outer" -- /usr/bin/cat inner/README.md
    assert_status 0 || return 1
    assert_eq "$OUT" "hello" "the outer project, with the inner one in it" || return 1
    run_avm exec --box "$BOX" --project "$_outer/inner" -- /usr/bin/cat README.md
    assert_status 0 || return 1
}

test_a_path_with_spaces() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/my project (v2); \$(x)"
    make_repository "$_project" || { fail "cannot make the test repository"; return 1; }
    run_avm exec --box "$BOX" --project "$_project" -- /bin/sh -c 'pwd -P; git status --short'
    assert_status 0 || return 1
    assert_out_contains "$_project" || return 1
    assert_out_contains "nested/" || return 1
    make_project "$SCRATCH/plain"
    run_avm exec --box "$BOX" --project "$SCRATCH/plain" -- /usr/bin/true
    assert_status 0 || return 1
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

test_session_report_and_undo() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _project="$SCRATCH/project"
    make_project "$_project"
    run_avm session start --project "$_project" --json
    assert_status 0 || return 1
    local _session
    _session="$(json_value id)"
    [ -n "$_session" ] || { fail "session start printed no id"; return 1; }
    run_avm exec --box "$BOX" --project "$_project" -- /bin/sh -c 'echo changed in the box > README.md; echo new > added.txt; rm build.sh'
    assert_status 0 || return 1
    run_avm session report "$_session"
    assert_status 0 || return 1
    assert_out_contains "README.md" || return 1
    assert_out_contains "added.txt" || return 1
    assert_out_contains "build.sh" || return 1
    run_avm session undo "$_session"
    assert_status 0 || return 1
    assert_eq "$(/bin/cat "$_project/README.md")" "hello" "the file after undo" || return 1
    assert_missing "$_project/added.txt" || return 1
    assert_exists "$_project/build.sh" || return 1
}
