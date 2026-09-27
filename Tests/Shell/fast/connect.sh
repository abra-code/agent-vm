#!/bin/bash
#
# Tests/Shell/fast/connect.sh - agent-vm connect and its other name, avm, without a virtual
# machine: the name dispatch, the list of what the picker offers, the order of the checks and
# their statuses, and --dry-run. Every test that would share a folder names one (a fast test
# runs inside its scratch folder, which holds the store, and such a folder cannot be shared).

# Two stopped boxes from a stand-in image, and a disposable one that never started.
make_boxes() {
    fake_image dev
    "$AGENT_VM" box create b1 --image dev > /dev/null || return 1
    "$AGENT_VM" box create b2 --image dev > /dev/null || return 1
    "$AGENT_VM" box create t1 --image dev --disposable > /dev/null || return 1
    make_project "$SCRATCH/project"
}

test_avm_is_connect_under_another_name() {
    run_avm --version
    local _version="$OUT"
    run_avm_link --version
    assert_status 0 || return 1
    assert_eq "$OUT" "$_version" "avm --version" || return 1
    run_avm_link --help
    assert_status 0 || return 1
    assert_out_contains "USAGE: avm" || return 1
    # A link to the link is avm too; a link under any other name is plain agent-vm.
    /bin/ln -s "$SCRATCH/avm" "$SCRATCH/avm-again" || return 1
    /bin/mkdir -p "$SCRATCH/deeper" || return 1
    /bin/ln -s "$SCRATCH/avm-again" "$SCRATCH/deeper/avm" || return 1
    run_cmd "$SCRATCH/deeper/avm" --help
    assert_status 0 || return 1
    assert_out_contains "USAGE: avm" || return 1
    /bin/ln -s "$AGENT_VM" "$SCRATCH/vm" || return 1
    run_cmd "$SCRATCH/vm" --help
    assert_status 0 || return 1
    assert_out_contains "USAGE: agent-vm" || return 1
    # And agent-vm connect is the same command.
    run_avm connect --help
    assert_status 0 || return 1
    assert_out_contains "agent-vm connect [<box>]" || return 1
}

test_connect_list_shows_what_the_picker_offers() {
    make_boxes || return 1
    run_avm_link list --json --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_json project "$(cd "$SCRATCH/project" && /bin/pwd -P)" || return 1
    # The disposable box that never started is not offered.
    assert_json boxes 2 || return 1
    assert_json boxes.0.name b1 || return 1
    assert_json boxes.0.state stopped || return 1
    assert_json boxes.0.offered true || return 1
    assert_json boxes.1.name b2 || return 1
    assert_not_contains "$OUT" '"t1"' "the list" || return 1
    run_avm_link list --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "Stopped" || return 1
    assert_out_contains "  b1  dev  stopped" || return 1
    assert_not_contains "$OUT" "t1" "the list" || return 1
    # A folder that cannot be shared is said, not refused.
    run_avm_link list --json --project /
    assert_status 0 || return 1
    assert_contains "$(json_value projectProblem)" "whole disk" "projectProblem" || return 1
}

test_connect_needs_a_terminal() {
    make_boxes || return 1
    # The picker: the plain list first, then why nothing was chosen.
    run_avm_link --project "$SCRATCH/project"
    assert_status 64 || return 1
    assert_out_contains "  b2  dev  stopped" || return 1
    assert_err_contains "choosing needs a terminal" || return 1
    # A session.
    run_avm_link b1 --shell --project "$SCRATCH/project"
    assert_status 64 || return 1
    assert_err_contains "the session runs on this terminal" || return 1
    run_avm connect b1 --no-project -- true
    assert_status 64 || return 1
    assert_err_contains "agent-vm connect: the session runs on this terminal" || return 1
}

test_connect_refuses_unknown_boxes_first() {
    make_boxes || return 1
    run_avm_link nope --shell --project "$SCRATCH/project"
    assert_status 1 || return 1
    assert_err_contains "no box nope" || return 1
    # A temporary box that is not running is not started again.
    run_avm_link t1 --project "$SCRATCH/project"
    assert_status 1 || return 1
    assert_err_contains "box t1 is a temporary box that is not running" || return 1
    # With no box at all, nothing to offer comes before the terminal.
    /bin/rm -rf "$AGENT_VM_HOME/Boxes"
    run_avm_link --project "$SCRATCH/project"
    assert_status 1 || return 1
    assert_err_contains "no boxes to connect to" || return 1
}

test_connect_options_that_do_not_go_together() {
    run_avm_link --shell -- ls
    assert_status 64 || return 1
    run_avm_link --project x --no-project
    assert_status 64 || return 1
    run_avm_link nope --box other
    assert_status 64 || return 1
    run_avm_link b1 --secret "bad name"
    assert_status 64 || return 1
    run_avm_link b1 --env "=x"
    assert_status 64 || return 1
}

test_connect_dry_run_names_every_step() {
    make_boxes || return 1
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    run_avm_link b1 --shell --dry-run --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "avm would:" || return 1
    assert_out_contains "  start box b1" || return 1
    assert_out_contains "  share $_project (read-write)" || return 1
    assert_out_contains "  run: agent-vm exec --tty --box b1 --project $_project -- /bin/sh -c 'exec \"\$SHELL\" -l'" || return 1
    run_avm_link b1 --dry-run --no-project --env X=1 -- make "a b"
    assert_status 0 || return 1
    assert_not_contains "$OUT" "share" "the steps" || return 1
    assert_out_contains "--env X=1 -- /bin/sh -c" || return 1
    assert_out_contains "sh make 'a b'" || return 1
    # A box named like one of avm's words, with --box.
    run_avm box create list --image dev
    assert_status 0 || return 1
    run_avm_link --box list --dry-run --no-project
    assert_status 0 || return 1
    assert_out_contains "  start box list" || return 1
    # Nothing was remembered or changed.
    assert_missing "$AGENT_VM_HOME/connect.json" || return 1
}

test_connect_dry_run_snapshots_read_write_shares() {
    make_boxes || return 1
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    run_avm_link b1 --shell --dry-run --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "  snapshot $_project" || return 1
    assert_out_contains "  report what changed in $_project, then keep or undo it" || return 1
    # Read only: nothing can change, so no snapshot, and exec shares it read only.
    run_avm_link b1 --shell --dry-run --read-only --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "  share $_project (read only)" || return 1
    assert_out_contains "--project $_project --read-only --" || return 1
    assert_not_contains "$OUT" "  snapshot " "the steps" || return 1
    assert_not_contains "$OUT" "report what changed" "the steps" || return 1
    run_avm_link b1 --shell --dry-run --no-snapshot --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "  share $_project (read-write)" || return 1
    assert_not_contains "$OUT" "  snapshot " "the steps" || return 1
    # A dry run takes no snapshot.
    run_avm session list
    assert_out_contains "No sessions." || return 1
}

test_read_only_needs_a_folder() {
    run_avm_link b1 --read-only --no-project
    assert_status 64 || return 1
    assert_err_contains "--read-only and --no-project do not go together" || return 1
}

test_connect_refuses_the_home_folder() {
    make_boxes || return 1
    avm_link || return 1
    (cd "$HOME" && "$SCRATCH/avm" b1 --dry-run > "$SCRATCH/.out" 2> "$SCRATCH/.err"; printf '%s' "$?" > "$SCRATCH/.status")
    STATUS="$(/bin/cat "$SCRATCH/.status")"
    ERR="$(/bin/cat "$SCRATCH/.err")"
    printf '$ (in ~) avm b1 --dry-run\n%s\n[status %s]\n' "$ERR" "$STATUS"
    assert_status 1 || return 1
    assert_err_contains "home folder" || return 1
    assert_err_contains "or none with --no-project" || return 1
}

test_build_made_the_avm_link() {
    local _dir
    _dir="$(/usr/bin/dirname "$AGENT_VM")"
    case "$_dir" in
        */.build/signed/*) ;;
        *) skip "not the signed build: $AGENT_VM"; return 0 ;;
    esac
    [ -L "$_dir/avm" ] || { fail "$_dir/avm is not a symlink"; return 1; }
    local _target
    _target="$(/usr/bin/readlink "$_dir/avm")"
    assert_eq "$_target" "agent-vm" "the avm link" || return 1
}
