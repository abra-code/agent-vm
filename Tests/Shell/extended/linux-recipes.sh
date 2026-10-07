#!/bin/bash
#
# Tests/Shell/extended/linux-recipes.sh - images built from a ready Linux image with recipes
# (image create --from): a recipe's steps, copies, checks and input files, a larger disk, a
# failing recipe, and the sudo recipe beside an image without it. From the ready Linux image
# $AGENT_VM_TEST_LINUX_IMAGE; without it every test is skipped. Each build takes about 10
# seconds. The test that installs Node and the agents downloads about 400 MB and runs only with
# AGENT_VM_TEST_LINUX_AGENTS=1.

# write_recipe <folder> <json>
write_recipe() {
    /bin/mkdir -p "$1/files"
    printf '%s\n' "$2" > "$1/recipe.json"
}

# image_folder <image>: the image's folder in the store.
image_folder() {
    "$AGENT_VM" image info "$1" --json | /usr/bin/jq -r .path
}

# A root step, a step of the box user, a copied file and checks; the new image is a Linux
# machine of its own, keeps the recipe, and every box of it has what the recipe made and a
# machine id of its own.
test_linux_derived_image_with_a_recipe() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-limg-$$"
    local _one="shtest-limg-a-$$"
    local _two="shtest-limg-b-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_one"
    cleanup_on_exit box "$_two"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{
      "version": 1,
      "guest": "linux",
      "description": "shell test",
      "steps": [
        { "name": "tool", "user": "root", "copy": "files/hello", "to": "/usr/local/bin/shtest-hello", "mode": "0755" },
        { "name": "as root", "user": "root", "run": "echo \"$(id -un) for $AGENT_VM_BOX_USER\" > /etc/shtest-root" },
        { "name": "note", "run": "echo \"built for $AGENT_VM_BOX_USER in $HOME\" > ~/shtest-note.txt" }
      ],
      "checks": ["shtest-hello", "cat ~/shtest-note.txt"]
    }'
    printf '#!/bin/sh\necho hello from the image\n' > "$SCRATCH/recipe/files/hello"

    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "check shtest-hello: hello from the image" || return 1
    assert_out_contains "[2/3] as root (as root)" || return 1
    run_avm image list
    assert_out_contains "$_image  ready" || return 1
    assert_out_contains "from \"$LINUX_TEST_IMAGE\" image  recipe shell test" || return 1
    assert_eq "$(image_value "$_image" guest)" "linux" "the image's guest" || return 1
    assert_eq "$(image_value "$_image" formatVersion)" "3" "the record's format" || return 1
    assert_eq "$(image_value "$_image" guestVersion)" "$("$AGENT_VM" --version)" "the daemon's version" || return 1
    # A Linux machine's files, and an identifier of its own.
    local _folder
    _folder="$(image_folder "$_image")"
    local _base
    _base="$(image_folder "$LINUX_TEST_IMAGE")"
    local _file
    for _file in Disk.img EFIVariableStore MachineIdentifier console.log Recipes/1-recipe/recipe.json Recipes/1-recipe/files/hello; do
        assert_exists "$_folder/$_file" || return 1
    done
    for _file in AuxiliaryStorage HardwareModel Password Seed.iso; do
        assert_missing "$_folder/$_file" || return 1
    done
    /usr/bin/cmp -s "$_folder/MachineIdentifier" "$_base/MachineIdentifier"
    local _same=$?
    [ "$_same" -ne 0 ] || { fail "the new image has its base's machine identifier"; return 1; }

    run_avm box create "$_one" --image "$_image"
    assert_status 0 || return 1
    run_avm box create "$_two" --image "$_image"
    assert_status 0 || return 1
    run_avm box start "$_one"
    assert_status 0 || return 1
    run_avm box start "$_two"
    assert_status 0 || return 1
    run_avm exec --box "$_one" -- /bin/sh -c 'shtest-hello; cat ~/shtest-note.txt /etc/shtest-root'
    local _output="$OUT"
    local _status="$STATUS"
    local _first
    _first="$("$AGENT_VM" exec --box "$_one" -- /usr/bin/cat /etc/machine-id)"
    local _second
    _second="$("$AGENT_VM" exec --box "$_two" -- /usr/bin/cat /etc/machine-id)"
    "$AGENT_VM" box stop "$_one"
    "$AGENT_VM" box stop "$_two"
    "$AGENT_VM" box delete "$_one"
    "$AGENT_VM" box delete "$_two"
    "$AGENT_VM" image delete "$_image"
    [ "$_status" -eq 0 ] || { fail "exec in the derived image's box failed ($_status)"; return 1; }
    assert_eq "$_output" $'hello from the image\nbuilt for agent in /home/agent\nroot for agent' "the recipe's work" || return 1
    [ "${#_first}" -eq 32 ] || { fail "the first box's machine id is [$_first]"; return 1; }
    [ "${#_second}" -eq 32 ] || { fail "the second box's machine id is [$_second]"; return 1; }
    [ "$_first" != "$_second" ] || { fail "two boxes of the image have one machine id: $_first"; return 1; }
}

# A larger disk is the file made longer on the Mac; the system grows into it when it boots,
# and the build checks that it did. A smaller one is refused before anything is cloned.
test_linux_derived_image_with_a_larger_disk() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lbig-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    # An empty operand would end the whole run in bash 3.2: checked before the arithmetic.
    local _bytes
    _bytes="$(image_value "$LINUX_TEST_IMAGE" diskBytes)"
    case "$_bytes" in
        ''|*[!0-9]*) fail "image $LINUX_TEST_IMAGE has no disk size: [$_bytes]"; return 1 ;;
    esac
    local _base_gb=$(( _bytes / 1073741824 ))
    local _gb=$(( _base_gb + 8 ))
    # What the root file system has, in GB, as the last line of the check's output.
    write_recipe "$SCRATCH/recipe" '{"version": 1, "guest": "linux", "checks": ["echo \"root has $(df -BG --output=size / | tail -n 1 | tr -d \" G\") GB\""]}'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --disk-gb $(( _base_gb - 1 ))
    assert_status 1 || return 1
    assert_err_contains "the disk can only grow, by at least 1 GB: $LINUX_TEST_IMAGE's is $_base_gb GB" || return 1
    assert_eq "$(image_state "$_image")" "" "the refused image" || return 1

    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --disk-gb "$_gb"
    assert_status 0 || return 1
    assert_out_contains "Growing the disk from $_base_gb to $_gb GB" || return 1
    assert_out_contains "root file system grown to" || return 1
    local _root
    _root="$(printf '%s\n' "$OUT" | /usr/bin/sed -n 's/.*: root has \([0-9]*\) GB$/\1/p')"
    [ -n "$_root" ] || { fail "the check did not say the root's size"; return 1; }
    [ "$_root" -ge $(( _gb - 2 )) ] || { fail "the root file system has $_root GB on a $_gb GB disk"; return 1; }
    assert_eq "$(image_value "$_image" diskBytes)" "$(( _gb * 1073741824 ))" "the record's disk size" || return 1
    assert_eq "$(/usr/bin/stat -f %z "$(image_folder "$_image")/Disk.img")" "$(( _gb * 1073741824 ))" "the disk file's size" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

test_linux_failing_recipe() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lbad-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "guest": "any", "steps": [{"name": "fine", "run": "true"}, {"name": "breaks", "run": "echo about to fail; exit 3"}]}'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --json
    assert_status 1 || return 1
    assert_err_contains "recipe step 2 (breaks)" || return 1
    assert_err_events || return 1
    assert_err_contains '"step":"clone"' || return 1
    assert_err_contains '{"event":"log","image":"'"$_image"'","message":"about to fail","output":true}' || return 1
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
    assert_contains "$(image_value "$_image" failure)" "recipe step 2 (breaks)" "the image's failure" || return 1
    # No virtual machine is left behind by the failure.
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# An input file is streamed to /var/tmp/agent-vm-inputs (a Linux guest has no /private), the
# steps see its path, and the folder is gone from the image afterwards.
test_linux_inputs_are_streamed_and_removed() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lin-$$"
    local _box="shtest-linbox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{
      "version": 1,
      "guest": "linux",
      "inputs": { "data": { "description": "any file" } },
      "steps": [
        { "name": "keep", "run": "echo \"$AGENT_VM_INPUT_DATA\" > ~/shtest-path.txt && cp \"$AGENT_VM_INPUT_DATA\" ~/shtest-kept.txt && stat -c \"%U %a\" \"$AGENT_VM_INPUT_DATA\" > ~/shtest-owner.txt" }
      ],
      "checks": ["cat ~/shtest-kept.txt"]
    }'
    printf 'given at build time\n' > "$SCRATCH/the input.txt"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --input data="$SCRATCH/the input.txt" --json
    assert_status 0 || return 1
    assert_err_contains '"step":"recipe-input"' || return 1
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(/usr/bin/jq -r '.recipe.inputs[0] | "\(.name) \(.file) \(.bytes)"' "$SCRATCH/record.json")" "data the input.txt 20" "the recorded input" || return 1
    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" --user root -- /bin/sh -c 'cat /home/agent/shtest-path.txt /home/agent/shtest-kept.txt /home/agent/shtest-owner.txt; ls /var/tmp/agent-vm-inputs 2>&1; ls -d /private 2>&1'
    local _output="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    assert_contains "$_output" "/var/tmp/agent-vm-inputs/data/the input.txt" "the input's path" || return 1
    assert_contains "$_output" "given at build time" "the input's contents" || return 1
    assert_contains "$_output" "root 644" "the input's owner and mode" || return 1
    assert_contains "$_output" "cannot access '/var/tmp/agent-vm-inputs'" "the inputs folder after the build" || return 1
    assert_contains "$_output" "cannot access '/private'" "a macOS path in a Linux guest" || return 1
}

# An image has no sudo for the box user: sudo is refused, and the refusal with the command is
# in the system's journal, which is how one sees what an agent tried to install.
test_an_image_without_the_sudo_recipe_refuses_sudo() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lnosudo-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- sudo -n true
    local _quiet="$STATUS $ERR"
    run_avm exec --box "$_box" -- sudo apt-get install -y shtest-package
    local _asked="$STATUS $ERR"
    run_avm exec --box "$_box" --user root -- /usr/bin/journalctl -t sudo --no-pager
    local _journal="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    assert_contains "$_quiet" "1 sudo: a password is required" "sudo -n" || return 1
    assert_contains "$_asked" "1 sudo: a terminal is required to read the password" "sudo" || return 1
    assert_contains "$_journal" "agent : user NOT in sudoers" "the journal" || return 1
    assert_contains "$_journal" "COMMAND=/usr/bin/apt-get install -y shtest-package" "the journal" || return 1
}

# The bundled sudo recipe: the image's record names it, and in a box of the image the box user
# becomes root without a password.
test_the_sudo_recipe_gives_sudo_and_the_record_says_so() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lsudo-$$"
    local _box="shtest-lsudobox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$TESTS_DIR/../../Recipes/linux-sudo/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "no password is asked of agent" || return 1
    run_avm image list
    assert_out_contains "recipe sudo without a password for the box user" || return 1
    run_avm image info "$_image" --json
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(/usr/bin/jq -r '.recipes | map(.name) | join(" ")' "$SCRATCH/record.json")" "linux-sudo" "the image's recipes" || return 1
    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'sudo -n id -u; id -nG; sudo -n stat -c "%U %a" /etc/sudoers.d/agent-vm'
    local _output="$OUT"
    local _status="$STATUS"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    [ "$_status" -eq 0 ] || { fail "sudo in a box of the image failed ($_status)"; return 1; }
    # Root through the rule, and still no group but its own.
    assert_eq "$_output" $'0\nagent\nroot 440' "sudo in the box" || return 1
}

# Node 24 from nodejs.org, Python, and the agents' command-line tools, the same recipe that a
# macOS image takes. Downloads about 400 MB, so only when asked for. The image is kept under
# the name in $AGENT_VM_TEST_LINUX_AGENT_IMAGE when that is set (and no image has the name).
test_linux_node_and_the_agents() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    if [ "${AGENT_VM_TEST_LINUX_AGENTS:-}" != "1" ]; then
        skip "set AGENT_VM_TEST_LINUX_AGENTS=1 to build an image with Node and the agents (downloads about 400 MB)"
        return 0
    fi
    local _recipes="$TESTS_DIR/../../Recipes"
    local _keep="${AGENT_VM_TEST_LINUX_AGENT_IMAGE:-}"
    local _image="shtest-lagents-$$"
    if [ -n "$_keep" ]; then
        local _kept
        _kept="$(image_state "$_keep")"
        if [ -n "$_kept" ]; then
            skip "image $_keep (AGENT_VM_TEST_LINUX_AGENT_IMAGE) is there already"
            return 0
        fi
        _image="$_keep"
    else
        cleanup_on_exit image "$_image"
    fi
    local _box="shtest-lagentsbox-$$"
    cleanup_on_exit box "$_box"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$_recipes/linux-node/recipe.json" --recipe "$_recipes/linux-python/recipe.json" --recipe "$_recipes/agent-clis/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "check node --version: v24." || return 1
    assert_out_contains "check claude --version: " || return 1
    assert_out_contains "check codex --version: " || return 1
    assert_out_contains "check opencode --version: " || return 1
    assert_out_contains "check uv --version: uv " || return 1
    # In a box on the allowlist network: the tools are on the path of a plain exec, npm
    # installs through the proxy, and Node's own fetch does too.
    run_avm box create "$_box" --image "$_image" --allow pack:npm
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'node --version && command -v claude codex opencode uv python && mkdir -p ~/shtest-p && cd ~/shtest-p && npm init -y > /dev/null && npm install --no-fund --no-audit left-pad > /dev/null && ls node_modules'
    local _tools="$STATUS $OUT"
    run_avm exec --box "$_box" -- node -e 'fetch("https://registry.npmjs.org/left-pad").then(r => console.log("fetch", r.status))'
    local _fetch="$STATUS $OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    if [ -z "$_keep" ]; then
        "$AGENT_VM" image delete "$_image"
    fi
    assert_contains "$_tools" "0 v24." "the tools in a box" || return 1
    assert_contains "$_tools" "/home/agent/.local/bin/claude" "where npm put claude" || return 1
    assert_contains "$_tools" "left-pad" "npm install through the proxy" || return 1
    assert_eq "$_fetch" "0 fetch 200" "Node's fetch through the proxy" || return 1
}
