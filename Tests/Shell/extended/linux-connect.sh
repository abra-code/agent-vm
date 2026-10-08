#!/bin/bash
#
# Tests/Shell/extended/linux-connect.sh - agent-vm connect, as avm, with real Linux boxes: a
# temporary box from a Linux image (made, used and deleted in seconds), a command in the shared
# folder with the snapshot's report afterwards (a change kept, a change undone), and an agent
# found through the login shell. From the ready Linux image $AGENT_VM_TEST_LINUX_IMAGE; without
# it every test is skipped. The agent test also wants an image built with Recipes/linux-node
# and Recipes/agent-clis, named by $AGENT_VM_TEST_LINUX_AGENT_IMAGE. script(1) provides the
# terminal (on_terminal). Sessions the tests make are discarded at their end.

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

# changing_project <folder>: a project whose work.sh, run in the box, adds new.txt and an
# executable file (which the report flags), then .done.
changing_project() {
    make_project "$1"
    printf '%s\n' 'cd "$(/usr/bin/dirname "$0")" || exit 1' 'echo x > new.txt' \
        'printf "#!/bin/sh\n" > hook1; /usr/bin/chmod +x hook1' \
        'touch .done' > "$1/work.sh"
}

# linux_boxes: the names of the store's boxes made from $LINUX_TEST_IMAGE, one to a line.
linux_boxes() {
    "$AGENT_VM" box list --json | /usr/bin/jq -r --arg image "$LINUX_TEST_IMAGE" '.[] | select(.image == $image) | .name'
}

# A temporary box: made from the image, started, the command run in it on this terminal, then
# stopped and deleted, with the command's status passed back. No box is left.
test_avm_new_temporary_linux_box() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    local _before
    _before="$(linux_boxes)"
    on_terminal ':' "$SCRATCH/avm" new "$LINUX_TEST_IMAGE" --no-project -- /bin/sh -c 'echo "inside $(/usr/bin/uname -s) as $(/usr/bin/id -un)"; exit 7'
    assert_status 7 || return 1
    assert_out_contains "Creating box avm-$LINUX_TEST_IMAGE-" || return 1
    assert_out_contains "(temporary: deleted when you leave)" || return 1
    assert_out_contains "inside Linux as agent" || return 1
    assert_out_contains "stopped and deleted" || return 1
    assert_eq "$(linux_boxes)" "$_before" "the boxes afterwards" || return 1
    # The home is the folder a session without a project starts in, and the shell is bash.
    on_terminal ':' "$SCRATCH/avm" new "$LINUX_TEST_IMAGE" --no-project -- /bin/sh -c 'pwd; echo "shell $SHELL"'
    assert_status 0 || return 1
    assert_out_contains "/home/agent" || return 1
    assert_out_contains "shell /bin/bash" || return 1
    assert_eq "$(linux_boxes)" "$_before" "the boxes afterwards" || return 1
}

# A session in the folder, with the safety net: the folder is at its own path in the box, what
# the program changed is reported, with the executable file flagged, and kept; a second session
# is undone, and the folder is as it was.
test_avm_runs_in_the_folder_with_the_safety_net() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    changing_project "$SCRATCH/project"
    local _project
    _project="$(cd "$SCRATCH/project" && /bin/pwd -P)"
    on_terminal "$(answer_when_done "$_project/.done" 'k\n')" "$SCRATCH/avm" new "$LINUX_TEST_IMAGE" --project "$_project" -- /bin/sh -c "echo \"cwd=\$(pwd -P)\"; /bin/sh '$_project/work.sh'"
    local _id
    _id="$(session_id)"
    local _state
    _state="$(session_state "$_id")"
    "$AGENT_VM" session discard "$_id" > /dev/null 2>&1
    assert_status 0 || return 1
    assert_out_contains "Sharing $_project (read-write)" || return 1
    assert_out_contains "Snapshot of " || return 1
    assert_out_contains "cwd=$_project" || return 1
    assert_out_contains "review first: 1 medium" || return 1
    assert_out_contains "Kept. Undo later with: agent-vm session undo $_id" || return 1
    assert_exists "$_project/new.txt" || return 1
    assert_eq "$_state" "ended" "the kept session" || return 1
    # The files the box made belong to the Mac's user, as every file in the share does.
    assert_eq "$(/usr/bin/stat -f %Su "$_project/new.txt")" "$(/usr/bin/id -un)" "the owner of a file made in the box" || return 1

    /bin/rm -f "$_project/new.txt" "$_project/hook1" "$_project/.done"
    on_terminal "$(answer_when_done "$_project/.done" 'u\n')" "$SCRATCH/avm" new "$LINUX_TEST_IMAGE" --project "$_project" -- /bin/sh "$_project/work.sh"
    _id="$(session_id)"
    _state="$(session_state "$_id")"
    "$AGENT_VM" session discard "$_id" > /dev/null 2>&1
    assert_status 0 || return 1
    assert_out_contains "Restored $_project to its state at" || return 1
    assert_missing "$_project/new.txt" || return 1
    assert_missing "$_project/hook1" || return 1
    assert_exists "$_project/README.md" || return 1
    assert_eq "$_state" "undone" "the undone session" || return 1
}

# An agent is looked for, and run, through the login shell, which is where the box user's own
# tool folder (~/.local/bin, where npm put the agents) comes onto the path. A scratch catalog
# ($AGENT_VM_AGENTS_FILE), so the store's own agents are never touched.
test_avm_finds_an_agent() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="${AGENT_VM_TEST_LINUX_AGENT_IMAGE:-}"
    if [ -z "$_image" ]; then
        skip "set AGENT_VM_TEST_LINUX_AGENT_IMAGE to a Linux image built with Recipes/linux-node and Recipes/agent-clis"
        return 0
    fi
    local _state
    _state="$(image_state "$_image")"
    if [ "$_state" != "ready" ]; then
        skip "no ready image $_image (AGENT_VM_TEST_LINUX_AGENT_IMAGE)"
        return 0
    fi
    avm_link || return 1
    printf '%s\n' '{"version": 1, "agents": [' \
        '{"id": "probe", "name": "Probe", "command": ["opencode", "--version"]},' \
        '{"id": "missing", "name": "Missing", "command": ["no-such-agent"], "install": "npm install --global no-such-agent"}' \
        ']}' > "$SCRATCH/agents.json"
    export AGENT_VM_AGENTS_FILE="$SCRATCH/agents.json"
    on_terminal ':' "$SCRATCH/avm" new "$_image" --agent probe --no-project
    local _found="$STATUS"
    local _output="$OUT"
    on_terminal ':' "$SCRATCH/avm" new "$_image" --agent missing --no-project
    unset AGENT_VM_AGENTS_FILE
    assert_eq "$_found" "0" "the status of the agent's run" || return 1
    assert_contains "$_output" "Probe in box avm-$_image-" "the agent's run" || return 1
    assert_not_contains "$_output" "not installed" "the agent's run" || return 1
    # opencode --version prints a version number.
    case "$_output" in
        *[0-9].[0-9]*) ;;
        *) fail "no version in the output"; return 1 ;;
    esac
    assert_status 1 || return 1
    assert_out_contains "Missing (no-such-agent) is not installed in box avm-$_image-" || return 1
    assert_out_contains "then npm install --global no-such-agent" || return 1
}
