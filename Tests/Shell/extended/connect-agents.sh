#!/bin/bash
#
# Tests/Shell/extended/connect-agents.sh - avm with agents, on a real box from an image built with
# Recipes/agent-clis ($AGENT_VM_TEST_AGENT_IMAGE; without it the tests are skipped): the check
# that an agent is installed, through the login shell as the agent itself runs, the message when
# it is not, and the launch picker marking it. The agents come from a scratch catalog
# ($AGENT_VM_AGENTS_FILE), so the store's own agents are never touched. script(1) provides the
# terminal (on_terminal).

TEST_IMAGE="${AGENT_VM_TEST_AGENT_IMAGE:-}"

file_setup() {
    if [ -z "$TEST_IMAGE" ]; then
        printf 'no agent image (set AGENT_VM_TEST_AGENT_IMAGE to an image built with Recipes/agent-clis)' > "$FILE_SCRATCH/no-box"
        return 0
    fi
    start_file_box "shtest-agents-$$"
}

file_teardown() {
    stop_file_box
}

# agents_file: a catalog with an agent the image has (opencode, asked for its version) and one it
# lacks; exported as AGENT_VM_AGENTS_FILE.
agents_file() {
    printf '%s\n' '{"version": 1, "agents": [' \
        '{"id": "probe", "name": "Probe", "command": ["opencode", "--version"]},' \
        '{"id": "missing", "name": "Missing", "command": ["no-such-agent"], "install": "npm install --global no-such-agent"}' \
        ']}' > "$SCRATCH/agents.json"
    export AGENT_VM_AGENTS_FILE="$SCRATCH/agents.json"
}

test_connect_probe_finds_the_agents() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    agents_file
    on_terminal ':' "$SCRATCH/avm" "$BOX" --agent probe --no-project
    assert_status 0 || return 1
    assert_out_contains "Probe in box $BOX" || return 1
    assert_not_contains "$OUT" "not installed" "the output" || return 1
    # opencode --version prints a version number.
    case "$OUT" in
        *[0-9].[0-9]*) ;;
        *) fail "no version in the output"; return 1 ;;
    esac
}

test_connect_says_what_is_not_installed() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    agents_file
    on_terminal ':' "$SCRATCH/avm" "$BOX" --agent missing --no-project
    assert_status 1 || return 1
    assert_out_contains "Missing (no-such-agent) is not installed in box $BOX" || return 1
    assert_out_contains "then npm install --global no-such-agent" || return 1
}

test_connect_launch_picker_marks_missing_agents() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    agents_file
    # Enter takes the first row that can be chosen: the probe agent. Typed once the picker shows
    # (after the probe): script(1) sends Control-D when its input ends, which quits the picker.
    on_terminal "/bin/sleep 8; printf '\\r'" "$SCRATCH/avm" "$BOX" --no-project
    assert_status 0 || return 1
    assert_out_contains "Run in box $BOX (kept)" || return 1
    assert_out_contains "not installed" || return 1
    assert_out_contains "Probe in box $BOX" || return 1
}
