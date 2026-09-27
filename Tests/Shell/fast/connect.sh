#!/bin/bash
#
# Tests/Shell/fast/connect.sh - agent-vm connect and its other name, avm, without a virtual
# machine: the name dispatch, the list of what the picker offers, the order of the checks and
# their statuses, --dry-run, and the agents catalog (the built-in file next to agent-vm, user
# entries, a secret's state in a test Keychain service). Every test that would share a folder names one (a fast test
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
    # The image, not usable for a new box: its guest daemon cannot run terminal sessions.
    assert_json images.0.name dev || return 1
    assert_json images.0.offered false || return 1
    assert_contains "$(json_value images.0.reason)" "update-guest dev" "the image's reason" || return 1
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
    assert_err_contains "no boxes and no ready images" || return 1
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
    run_avm_link --box list --dry-run --no-project --shell
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

test_connect_agents_lists_the_catalog() {
    export AGENT_VM_SECRET_SERVICE="agent-vm-shtest-$$-$RANDOM"
    trap '"$AGENT_VM" secret delete ANTHROPIC_API_KEY > /dev/null 2>&1' EXIT
    run_avm_link agents --json
    assert_status 0 || return 1
    assert_json 0.id claude || return 1
    assert_json 1.id codex || return 1
    assert_json 2.id opencode || return 1
    assert_json 0.source built-in || return 1
    assert_json 0.secrets.1.env ANTHROPIC_API_KEY || return 1
    assert_json 0.secrets.1.state missing || return 1
    run_avm_input "sk-shtest-$RANDOM" secret set ANTHROPIC_API_KEY
    assert_status 0 || return 1
    run_avm_link agents --json
    assert_json 0.secrets.1.state set || return 1
    run_avm_link agents
    assert_status 0 || return 1
    assert_out_contains "claude  Claude Code  (built-in)" || return 1
    assert_out_contains "secrets (one of): CLAUDE_CODE_OAUTH_TOKEN missing; ANTHROPIC_API_KEY set" || return 1
}

test_user_agents_replace_and_problems_show() {
    /bin/mkdir -p "$AGENT_VM_HOME/Agents" || return 1
    printf '%s\n' '{"name": "My Claude", "command": ["claude", "--verbose"]}' > "$AGENT_VM_HOME/Agents/claude.json"
    printf '%s\n' '{"name": "Aider", "command": ["aider"], "allow": ["api.example.com"]}' > "$AGENT_VM_HOME/Agents/aider.json"
    printf '%s\n' '{"name": "Broken", "command": "broken"}' > "$AGENT_VM_HOME/Agents/broken.json"
    run_avm_link agents --json
    assert_status 0 || return 1
    assert_json 0.id claude || return 1
    assert_json 0.name "My Claude" || return 1
    assert_json 0.source user || return 1
    assert_json 0.replacesBuiltIn true || return 1
    assert_json 3.id aider || return 1
    assert_json 4.id broken || return 1
    assert_json 4.problem '"command" must be a list of words' || return 1
    run_avm_link agents
    assert_status 0 || return 1
    assert_out_contains "replaces the built-in one" || return 1
    assert_out_contains "cannot be used: \"command\" must be a list of words" || return 1
}

test_a_broken_built_in_catalog_fails_agents() {
    printf '{"version": true, "agents": []}\n' > "$SCRATCH/agents.json"
    export AGENT_VM_AGENTS_FILE="$SCRATCH/agents.json"
    run_avm_link agents
    assert_status 1 || return 1
    assert_err_contains '"version" must be 1' || return 1
    # --agent says why the agent is unknown.
    make_boxes || return 1
    run_avm_link b1 --agent claude --no-project --dry-run
    assert_status 64 || return 1
    assert_err_contains '"version" must be 1' || return 1
    assert_err_contains "no agent claude" || return 1
}

test_connect_dry_run_for_an_agent() {
    export AGENT_VM_SECRET_SERVICE="agent-vm-shtest-$$-$RANDOM"
    fake_image dev
    run_avm box create c1 --image dev --allow pack:anthropic
    assert_status 0 || return 1
    make_project "$SCRATCH/project"
    run_avm_link c1 --agent claude --dry-run --project "$SCRATCH/project"
    assert_status 0 || return 1
    assert_out_contains "  offer to set one of: CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY" || return 1
    assert_not_contains "$OUT" "ask to allow" "the steps" || return 1
    assert_out_contains "  start box c1" || return 1
    assert_out_contains "  check that claude is installed in the box" || return 1
    assert_out_contains "--env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 -- /bin/sh -c" || return 1
    # The setup that marks Claude Code's onboarding done runs first, then claude itself.
    assert_out_contains "hasCompletedOnboarding" || return 1
    assert_out_contains "exec \"\$0\" \"\$@\"' claude" || return 1
    # A box without the agent's hosts is asked; one with no folder shared still is.
    run_avm box create c2 --image dev --allow github.com
    assert_status 0 || return 1
    run_avm_link c2 --agent claude --dry-run --no-project
    assert_status 0 || return 1
    assert_out_contains "  ask to allow pack:anthropic in box c2" || return 1
    # Without a terminal, what to run must be named.
    run_avm_link c1 --project "$SCRATCH/project"
    assert_status 64 || return 1
    assert_err_contains "choosing what to run needs a terminal" || return 1
}

test_unknown_agent() {
    make_boxes || return 1
    run_avm_link b1 --agent nope --project "$SCRATCH/project"
    assert_status 64 || return 1
    assert_err_contains "no agent nope; avm agents lists them: claude, codex, opencode" || return 1
    run_avm_link b1 --agent claude --shell
    assert_status 64 || return 1
    assert_err_contains "do not go together" || return 1
}

test_connect_new_checks_names_first() {
    make_boxes || return 1
    fake_image half provisioning
    run_avm_link new dev --name "Bad Name" --shell
    assert_status 64 || return 1
    run_avm_link new dev --temp --name x --shell
    assert_status 64 || return 1
    run_avm_link new nope --shell --no-project
    assert_status 1 || return 1
    assert_err_contains "no image nope" || return 1
    run_avm_link new half --shell --no-project
    assert_status 1 || return 1
    assert_err_contains "it is provisioning" || return 1
    fake_image ready1 ready '["terminal"]'
    run_avm_link new ready1 --name b1 --shell --no-project
    assert_status 1 || return 1
    assert_err_contains "box b1 already exists" || return 1
    run_avm_link new ready1 --allow pack:nope --shell --no-project
    assert_status 1 || return 1
    assert_err_contains "pack:nope" || return 1
    # Nothing was made.
    run_avm box list --json
    assert_not_contains "$OUT" "avm-ready1" "the boxes" || return 1
}

test_connect_new_dry_run() {
    fake_image dev ready '["terminal"]'
    make_project "$SCRATCH/project"
    run_avm_link new dev --shell --dry-run --no-project --allow github.com
    assert_status 0 || return 1
    local _name
    _name="$(printf '%s\n' "$OUT" | /usr/bin/sed -n 's/^  create box \(avm-dev-[0-9a-f]\{6\}\) from image dev (temporary), allowing github.com$/\1/p')"
    [ -n "$_name" ] || { fail "no create line for a temporary box"; return 1; }
    assert_out_contains "  start box $_name, stopping it when process " || return 1
    assert_out_contains "  stop and delete box $_name" || return 1
    # Kept: no owner, no stop.
    run_avm_link new dev --name k1 --shell --dry-run --project "$SCRATCH/project" --cpus 2 --memory-gb 4
    assert_status 0 || return 1
    assert_out_contains "  create box k1 from image dev, 2 CPUs, 4 GB" || return 1
    assert_out_contains "  start box k1" || return 1
    assert_not_contains "$OUT" "stopping it when" "the steps" || return 1
    assert_not_contains "$OUT" "stop and delete" "the steps" || return 1
    # An agent's hosts come with the new box, and nothing is asked about them.
    run_avm_link new dev --agent opencode --dry-run --no-project
    assert_status 0 || return 1
    assert_out_contains "(temporary), allowing opencode.ai, models.opencode.ai" || return 1
    assert_not_contains "$OUT" "ask to allow" "the steps" || return 1
    # Nothing was made.
    run_avm box list --json
    assert_not_contains "$OUT" '"name"' "the boxes" || return 1
}

test_connect_new_images_without_a_terminal_feature_are_refused() {
    fake_image old
    run_avm_link new old --shell --dry-run --no-project
    assert_status 1 || return 1
    assert_err_contains "update it with agent-vm image update-guest old" || return 1
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
