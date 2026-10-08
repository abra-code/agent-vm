#!/bin/bash
#
# Tests/Shell/extended/linux-updates.sh - image update and image rebuild for Linux images: the
# tools' update steps, the system's package updates, the guest daemon, boxes made while an
# update runs, a cancel, and a rebuild from the image's base and from its release's cloud
# image. Every test works on an image of its own, built from the ready Linux image
# $AGENT_VM_TEST_LINUX_IMAGE (which is never changed); without it every test is skipped. The
# system update and the rebuild from the cloud image need the internet.

# write_recipe <folder> <json>
write_recipe() {
    /bin/mkdir -p "$1/files"
    printf '%s\n' "$2" > "$1/recipe.json"
}

# update_recipe <folder>: a recipe that writes a note, and whose update step adds a line to it
# ($AGENT_VM_PARAM_MARK: "slow" sleeps first, "fail" fails).
update_recipe() {
    write_recipe "$1" '{
      "version": 1,
      "guest": "linux",
      "description": "update test",
      "parameters": {"mark": {"default": "one"}},
      "steps": [{ "name": "note", "run": "echo \"built $AGENT_VM_PARAM_MARK\" > ~/shtest-upd.txt" }],
      "update": [{ "name": "note again", "run": "[ \"$AGENT_VM_PARAM_MARK\" != fail ] && { [ \"$AGENT_VM_PARAM_MARK\" != slow ] || sleep 20; } && echo \"updated $AGENT_VM_PARAM_MARK\" >> ~/shtest-upd.txt" }],
      "checks": ["tr \"\\n\" \",\" < ~/shtest-upd.txt"]
    }'
}

# The update steps run on a copy, which takes the image's place: the revision goes up, a box
# made before says so, a failing step leaves the image as it was, and a recreated box has what
# the update wrote.
test_linux_image_update_tools() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lupd-$$"
    local _box="shtest-lupdbox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    update_recipe "$SCRATCH/recipe"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1

    run_avm image update "$_image" --tools --set mark=two
    assert_status 0 || return 1
    assert_out_contains "Updating recipe (1 of 1): update test" || return 1
    assert_out_contains "built one,updated two," || return 1
    assert_out_contains "Image $_image is updated (revision 1): tools of recipe" || return 1
    assert_not_contains "$OUT" "Booting again" "a second boot" || return 1
    run_avm image info "$_image" --json
    assert_json state "ready" || return 1
    assert_json revision "1" || return 1
    assert_json guest "linux" || return 1
    assert_json recipes.0.parameters.mark "two" || return 1
    local _folder
    _folder="$(json_value path)"
    assert_missing "$_folder/Update" || return 1
    assert_missing "$_folder/Update.commit" || return 1
    local _file
    for _file in Disk.img EFIVariableStore MachineIdentifier image.json; do
        assert_exists "$_folder/$_file" || return 1
    done
    assert_missing "$_folder/AuxiliaryStorage" || return 1
    run_avm box list
    assert_out_contains "needs recreate: image $_image was updated since this box was made" || return 1

    # A failing update step: reported, and nothing of it is kept.
    run_avm image update "$_image" --tools --set mark=fail
    assert_status 1 || return 1
    assert_err_contains "recipe update step 1 (note again)" || return 1
    assert_out_contains "$_image is unchanged" || return 1
    run_avm image info "$_image" --json
    assert_json state "ready" || return 1
    assert_json revision "1" || return 1
    assert_json recipes.0.parameters.mark "two" || return 1
    assert_missing "$_folder/Update" || return 1

    run_avm box recreate "$_box"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/cat shtest-upd.txt
    local _output="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    assert_eq "$_output" $'built one\nupdated two' "the image after the updates" || return 1
}

# The system's part: the distribution's package updates. Whether there are any depends on the
# day, so both ends are right: a new revision, or nothing to update; the image is ready either
# way, and its record says when it was looked at. Then --if-older-than skips it without a boot.
test_linux_image_update_system() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lsys-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "guest": "linux", "steps": [{"name": "nothing", "run": "true"}], "checks": ["true"]}'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    local _began
    _began="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"

    run_avm image update "$_image" --system --json
    assert_status 0 || return 1
    assert_err_events || return 1
    assert_err_contains '"step":"system-update"' || return 1
    assert_err_contains '] package lists"' || return 1
    assert_err_contains '] system updates"' || return 1
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(/usr/bin/jq -r .state "$SCRATCH/record.json")" "ready" "the image's state" || return 1
    local _checked
    _checked="$(/usr/bin/jq -r '.systemCheckedAt // ""' "$SCRATCH/record.json")"
    # ISO 8601 times in UTC sort as text. A record without the stamp must not pass: "null"
    # sorts after every date.
    [ -n "$_checked" ] || { fail "the record has no systemCheckedAt"; return 1; }
    [ ! "$_checked" \< "$_began" ] || { fail "systemCheckedAt is $_checked, and the update began at $_began"; return 1; }
    assert_eq "$(/usr/bin/jq -r 'has("macOSCheckedAt")' "$SCRATCH/record.json")" "false" "a Mac's stamp" || return 1
    local _revision
    _revision="$(/usr/bin/jq -r '.revision // 0' "$SCRATCH/record.json")"
    case "$_revision" in
        0) assert_err_contains "Nothing to update in $_image" || return 1 ;;
        1) assert_err_contains '"step":"commit"' || return 1 ;;
        *) fail "the image's revision is $_revision"; return 1 ;;
    esac
    assert_eq "$(/usr/bin/jq -r '.linux.kernel | length > 0' "$SCRATCH/record.json")" "true" "the recorded kernel" || return 1

    # Looked at a moment ago: not looked at again, and nothing is booted.
    run_avm image update "$_image" --system --if-older-than 1
    assert_status 0 || return 1
    assert_out_contains "Image $_image: $(linux_test_system short) checked less than 1 hour ago: not checked again" || return 1
    assert_not_contains "$OUT" "Booting" "a skipped update" || return 1
    # The name macOS has for it is refused, with the one to use.
    run_avm image update "$_image" --macos
    assert_status 1 || return 1
    assert_err_contains "--macos is for macOS images; image $_image runs Linux: use --system" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# An image just built has this agent-vm's daemon: --guest finds nothing to do, boots once, and
# the image keeps its revision. The deprecated update-guest, which boots the image itself, is
# not there for a Linux image, and names the command that is.
test_linux_update_guest_is_a_no_op_for_the_same_daemon() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lguest-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "guest": "linux", "steps": [{"name": "nothing", "run": "true"}], "checks": ["true"]}'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    local _digest
    _digest="$(image_value "$_image" guestDigest)"
    local _local
    _local="$(/usr/bin/shasum -a 256 "$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest" | /usr/bin/cut -d ' ' -f 1)"
    assert_eq "$_digest" "$_local" "the daemon in a new image" || return 1

    run_avm image update "$_image" --guest
    assert_status 0 || return 1
    assert_out_contains "agent-vm-guest is already this agent-vm's" || return 1
    assert_out_contains "Image $_image is up to date: $(linux_test_system long)" || return 1
    assert_not_contains "$OUT" "Booting again" "a second boot" || return 1
    assert_eq "$(image_value "$_image" revision)" "" "the image's revision" || return 1

    local _before
    _before="$(/bin/cat "$(image_folder_of "$_image")/image.json")"
    run_avm image update-guest "$_image"
    assert_status 1 || return 1
    assert_err_contains "image update-guest is not there for Linux images; use \`agent-vm image update $_image --guest\`" || return 1
    assert_not_contains "$OUT" "Booting" "the refused command" || return 1
    assert_eq "$(/bin/cat "$(image_folder_of "$_image")/image.json")" "$_before" "the image's record" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# While an update runs on its copy, the image stays usable: a box is made from it as it is,
# the list says it is being updated, and a second update or a delete is refused as busy.
test_boxes_can_be_made_while_a_linux_image_updates() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lbusy-$$"
    local _box="shtest-lbusybox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    update_recipe "$SCRATCH/recipe"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1

    "$AGENT_VM" image update "$_image" --tools --set mark=slow > "$SCRATCH/slow.out" 2>&1 &
    local _update=$!
    wait_for_text "$SCRATCH/slow.out" "note again" 120 || { fail "the slow update did not reach its step"; kill "$_update"; return 1; }
    run_avm image list
    assert_out_contains "(being updated" || { kill "$_update"; return 1; }
    # The copy's guest is known to be a Linux one: it takes none of the macOS places.
    run_avm status --json
    assert_json runningVMs.linuxImages 1 || { kill "$_update"; return 1; }
    run_avm box create "$_box" --image "$_image"
    assert_status 0 || { kill "$_update"; return 1; }
    run_avm image update "$_image" --tools
    assert_status 1 || { kill "$_update"; return 1; }
    assert_err_contains "in use" || { kill "$_update"; return 1; }
    run_avm image delete "$_image"
    assert_status 1 || { kill "$_update"; return 1; }
    wait "$_update"
    assert_eq "$?" "0" "the slow update's status" || return 1
    run_avm status --json
    assert_json runningVMs.linuxImages 0 || return 1
    run_avm image info "$_image" --json
    assert_json revision "1" || return 1
    # The box was made from the image as it was, and says that the image moved on.
    run_avm box list
    assert_out_contains "needs recreate: image $_image was updated since this box was made" || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/cat shtest-upd.txt
    local _output="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    assert_eq "$_output" "built one" "the box made during the update" || return 1
}

# SIGINT during an update step: the copy's guest is shut down, the copy is removed, and the
# image is as it was: ready, at its revision, with no update folder.
test_linux_update_cancel_leaves_the_image() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lcancel-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    update_recipe "$SCRATCH/recipe"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    local _before
    _before="$(/bin/cat "$(image_folder_of "$_image")/image.json")"

    "$AGENT_VM" image update "$_image" --tools --set mark=slow > "$SCRATCH/update.out" 2> "$SCRATCH/update.err" &
    local _pid=$!
    wait_for_text "$SCRATCH/update.out" "note again" 120
    local _reached=$?
    kill -INT "$_pid"
    local _began
    _began="$(/bin/date +%s)"
    wait "$_pid"
    STATUS=$?
    local _took=$(( $(/bin/date +%s) - _began ))
    ERR="$(/bin/cat "$SCRATCH/update.err")"
    printf '%s\n%s\n[status %s after %s s]\n' "$(/bin/cat "$SCRATCH/update.out")" "$ERR" "$STATUS" "$_took"
    [ "$_reached" -eq 0 ] || { fail "the update did not reach its step within 120 s"; return 1; }
    assert_status 130 || return 1
    local _out
    _out="$(/bin/cat "$SCRATCH/update.out")"
    assert_contains "$_out" "Canceled; shutting down" "stdout" || return 1
    assert_not_contains "$_out" "did not shut down" "stdout" || return 1
    assert_contains "$_out" "$_image is unchanged" "stdout" || return 1
    assert_err_contains "Image $_image is unchanged: canceled by SIGINT" || return 1
    [ "$_took" -lt 60 ] || { fail "the cancel took $_took s"; return 1; }
    local _folder
    _folder="$(image_folder_of "$_image")"
    assert_missing "$_folder/Update" || return 1
    assert_missing "$_folder/Update.commit" || return 1
    assert_eq "$(/bin/cat "$_folder/image.json")" "$_before" "the image's record" || return 1
    # Usable at once: nothing holds it.
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# image_folder_of <image>: the image's folder in the store.
image_folder_of() {
    "$AGENT_VM" image info "$1" --json | /usr/bin/jq -r .path
}

# Built again from the image it was made from, with the recipe it keeps: a new image under the
# old name, and nothing left beside it.
test_linux_rebuild_from_its_base() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lreb-$$"
    local _box="shtest-lrebbox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    "$AGENT_VM" image delete "$_image.rebuild" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image.rebuild"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{
      "version": 1,
      "guest": "linux",
      "description": "rebuild test",
      "parameters": {"mark": {"default": "one"}},
      "steps": [{ "name": "note", "run": "echo \"built $AGENT_VM_PARAM_MARK\" > ~/shtest-reb.txt" }],
      "checks": ["cat ~/shtest-reb.txt"]
    }'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    local _created
    _created="$(image_value "$_image" createdAt)"
    /bin/sleep 1

    run_avm image rebuild "$_image" --set mark=two
    assert_status 0 || return 1
    assert_out_contains "Rebuilding $_image as $_image.rebuild, from $LINUX_TEST_IMAGE" || return 1
    assert_out_contains "check cat ~/shtest-reb.txt: built two" || return 1
    assert_out_contains "Image $_image is rebuilt: $(linux_test_system long)" || return 1
    assert_eq "$(image_state "$_image")" "ready" "the image's state" || return 1
    assert_eq "$(image_state "$_image.rebuild")" "" "the build's name afterwards" || return 1
    local _now
    _now="$(image_value "$_image" createdAt)"
    [ "$_now" != "$_created" ] || { fail "the image was not built again: created $_now"; return 1; }
    run_avm image info "$_image" --json
    assert_json guest "linux" || return 1
    assert_json derivedFrom.image "$LINUX_TEST_IMAGE" || return 1
    assert_json recipes.0.parameters.mark "two" || return 1

    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/cat shtest-reb.txt
    local _output="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    assert_eq "$_output" "built two" "the rebuilt image" || return 1
}

# Built again from its release's cloud image: the distribution's file is fetched (or reused) and checked,
# the system is set up and sealed as in a first build, and the recipe the image kept runs again,
# so an image made in two layers comes back as one. About a minute and a half.
test_linux_rebuild_from_the_cloud_image() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lfresh-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    "$AGENT_VM" image delete "$_image.rebuild" > /dev/null 2>&1
    cleanup_on_exit image "$_image.rebuild"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{
      "version": 1,
      "guest": "linux",
      "description": "rebuild test",
      "steps": [{ "name": "note", "run": "echo built > ~/shtest-reb.txt" }],
      "checks": ["cat ~/shtest-reb.txt"]
    }'
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1

    local _release
    _release="$(linux_test_release)"
    run_avm image rebuild "$_image" --linux "$_release" --json
    assert_status 0 || return 1
    assert_err_events || return 1
    local _step
    for _step in base-check unpack first-boot linux-setup recipe seal shutdown replace; do
        assert_err_contains "\"step\":\"$_step\"" || return 1
    done
    # Every event names the image, not the name it is built under.
    assert_not_contains "$ERR" "\"image\":\"$_image.rebuild\"" "the events" || return 1
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(/usr/bin/jq -r .name "$SCRATCH/record.json")" "$_image" "the record's name" || return 1
    assert_eq "$(/usr/bin/jq -r .state "$SCRATCH/record.json")" "ready" "the image's state" || return 1
    assert_eq "$(/usr/bin/jq -r .base.release "$SCRATCH/record.json")" "$_release" "the base's release" || return 1
    assert_eq "$(/usr/bin/jq -r 'has("derivedFrom")' "$SCRATCH/record.json")" "false" "a base image" || return 1
    assert_eq "$(/usr/bin/jq -r '.recipes | map(.name + ":" + (.inheritedFrom // "own")) | join(" ")' "$SCRATCH/record.json")" "recipe:own" "the recipes" || return 1
    assert_eq "$(image_state "$_image.rebuild")" "" "the build's name afterwards" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}
