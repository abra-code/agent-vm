#!/bin/bash
#
# Tests/Shell/extended/linux-updates.sh - image update and image rebuild for Linux images: the
# tools' update steps, the system's package updates, the guest daemon, boxes made while an
# update runs, a cancel, and a rebuild from the image's base and from its release's cloud
# image; a recipe run again (from a base that ran it, and with a new input file), and an image
# whose base changed. Every test works on an image of its own, built from the ready Linux image
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

# note_recipe <folder>: a recipe named after its folder with an input ("note") and a parameter
# ("mark"): its steps put the file and the mark in /opt, its update step writes the mark again,
# and its check prints both ("first note,one,").
note_recipe() {
    write_recipe "$1" '{
      "version": 1,
      "guest": "linux",
      "description": "input test",
      "inputs": {"note": {"description": "a small text file"}},
      "parameters": {"mark": {"default": "one"}},
      "steps": [{ "name": "note", "user": "root", "run": "cat \"$AGENT_VM_INPUT_NOTE\" > /opt/shtest-note.txt && echo \"$AGENT_VM_PARAM_MARK\" > /opt/shtest-mark.txt && chmod 0644 /opt/shtest-note.txt /opt/shtest-mark.txt" }],
      "update": [{ "name": "mark again", "user": "root", "run": "echo \"$AGENT_VM_PARAM_MARK\" > /opt/shtest-mark.txt" }],
      "checks": ["cat /opt/shtest-note.txt /opt/shtest-mark.txt | tr \"\\n\" \",\""]
    }'
}

# recipe_place: where the entry named "note" is in the recipes of the image record in $OUT.
recipe_place() {
    printf '%s' "$OUT" | /usr/bin/jq '[.recipes[].name] | index("note")'
}

# image create --from with a recipe the base ran already: it runs again, takes the base's entry
# in the new image's list, in its place, and the folder of the base's goes (0.7.56).
test_linux_a_recipe_the_base_ran_takes_its_place() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _base="shtest-lplb-$$"
    local _image="shtest-lpli-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    "$AGENT_VM" image delete "$_base" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    cleanup_on_exit image "$_base"
    note_recipe "$SCRATCH/note"
    printf 'first note\n' > "$SCRATCH/one.txt"
    printf 'second note\n' > "$SCRATCH/two.txt"
    run_avm image create "$_base" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/note/recipe.json" --input note="$SCRATCH/one.txt"
    assert_status 0 || return 1
    run_avm image info "$_base" --json
    local _place="$(recipe_place)"
    local _count="$(json_value recipes)"

    run_avm image create "$_image" --from "$_base" --recipe "$SCRATCH/note/recipe.json" --input note="$SCRATCH/two.txt" --set mark=two
    assert_status 0 || return 1
    assert_out_contains "note takes the place of the note recipe that ran before" || return 1
    assert_out_contains "second note,two," || return 1
    run_avm image info "$_image" --json
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/jq '[.recipes[] | select(.name == "note")] | length')" "1" "entries named note" || return 1
    assert_json recipes "$_count" || return 1
    assert_json "recipes.$_place.name" "note" || return 1
    assert_json "recipes.$_place.inputs.0.file" "two.txt" || return 1
    assert_json "recipes.$_place.parameters.mark" "two" || return 1
    assert_json "recipes.$_place.inheritedFrom" "" || return 1
    # One folder of it: the new one.
    local _folder="$(json_value path)"
    local _kept="$(json_value "recipes.$_place.folder")"
    assert_eq "$(/bin/ls "$_folder/Recipes" | /usr/bin/grep -c -- '-note$')" "1" "folders of the note recipe" || return 1
    assert_exists "$_folder/Recipes/$_kept/recipe.json" || return 1
    "$AGENT_VM" image delete "$_image"
    "$AGENT_VM" image delete "$_base"
}

# image update --tools --input: the recipe that has the input runs its steps again with the new
# file, and the image records it; what is refused is refused before anything boots (0.7.57).
test_linux_update_gives_a_recipe_a_new_input_file() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-lupi-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    note_recipe "$SCRATCH/note"
    printf 'first note\n' > "$SCRATCH/one.txt"
    printf 'second note\n' > "$SCRATCH/two.txt"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/note/recipe.json" --input note="$SCRATCH/one.txt"
    assert_status 0 || return 1

    run_avm image update "$_image" --tools --input note="$SCRATCH/two.txt"
    assert_status 0 || return 1
    assert_out_contains "Recipe note: its steps run again with two.txt" || return 1
    assert_out_contains "second note,one," || return 1
    assert_out_contains "Image $_image is updated (revision 1): " || return 1
    assert_out_contains "note from two.txt" || return 1
    run_avm image info "$_image" --json
    local _place="$(recipe_place)"
    assert_json revision "1" || return 1
    assert_json "recipes.$_place.inputs.0.file" "two.txt" || return 1
    assert_json "recipes.$_place.parameters.mark" "one" || return 1

    # Refused, and nothing boots.
    run_avm image update "$_image" --tools --input nosuch="$SCRATCH/two.txt"
    assert_status 1 || return 1
    assert_err_contains "--input nosuch: $_image keeps no recipe with that input (they have: note)" || return 1
    run_avm image update "$_image" --tools --input note="$SCRATCH/nosuch.txt"
    assert_status 1 || return 1
    assert_err_contains "does not exist" || return 1
    run_avm image update "$_image" --system --input note="$SCRATCH/two.txt"
    assert_status 64 || return 1
    assert_err_contains "--input gives a recipe a new file, for the tools update" || return 1
    assert_eq "$(image_value "$_image" revision)" "1" "the revision after the refusals" || return 1
    "$AGENT_VM" image delete "$_image"
}

# Three generations: first (the note recipe), mid (a copy of first), top (a recipe of its own,
# made from mid). An update gives mid's note another mark: top says it needs a rebuild, and the
# rebuild takes mid as it is now; the note recipe, which top inherited from first, does not run
# again over mid's newer state (0.7.58, 0.7.59).
test_linux_a_changed_base_asks_for_a_rebuild() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _first="shtest-lcbf-$$"
    local _mid="shtest-lcbm-$$"
    local _top="shtest-lcbt-$$"
    local _box="shtest-lcbbox-$$"
    local _image
    for _image in "$_top" "$_top.rebuild" "$_mid" "$_first"; do
        "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    done
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_top.rebuild"
    cleanup_on_exit image "$_top"
    cleanup_on_exit image "$_mid"
    cleanup_on_exit image "$_first"
    note_recipe "$SCRATCH/note"
    printf 'first note\n' > "$SCRATCH/one.txt"
    write_recipe "$SCRATCH/own" '{
      "version": 1,
      "guest": "linux",
      "description": "own test",
      "steps": [{ "name": "own", "user": "root", "run": "echo own > /opt/shtest-own.txt && chmod 0644 /opt/shtest-own.txt" }],
      "checks": ["cat /opt/shtest-own.txt"]
    }'
    run_avm image create "$_first" --from "$LINUX_TEST_IMAGE" --recipe "$SCRATCH/note/recipe.json" --input note="$SCRATCH/one.txt"
    assert_status 0 || return 1
    run_avm image create "$_mid" --from "$_first"
    assert_status 0 || return 1
    run_avm image create "$_top" --from "$_mid" --recipe "$SCRATCH/own/recipe.json"
    assert_status 0 || return 1
    run_avm image info "$_top" --json
    assert_json needs "0" || return 1

    run_avm image update "$_mid" --tools --set mark=two
    assert_status 0 || return 1
    run_avm image info "$_top" --json
    assert_json needs "1" || return 1
    assert_json needs.0.kind "rebuild" || return 1
    assert_json needs.0.reason "base-recipes-changed" || return 1
    assert_json needs.0.base "$_mid" || return 1
    run_avm image list
    assert_out_contains "image $_mid has other tools than when this one was made from it; \`agent-vm image rebuild $_top\` makes this one again from it" || return 1
    run_avm status
    assert_out_contains "from $_mid  needs rebuild" || return 1
    # The base's own plain update does not ask its images for anything more.
    run_avm image info "$_mid" --json
    assert_json needs "0" || return 1

    run_avm image rebuild "$_top"
    assert_status 0 || return 1
    assert_not_contains "$OUT" "parameters: mark=one" "the inherited note recipe run again" || return 1
    assert_out_contains "check cat /opt/shtest-own.txt: own" || return 1
    run_avm image info "$_top" --json
    local _place="$(recipe_place)"
    assert_json needs "0" || return 1
    assert_json "recipes.$_place.inheritedFrom" "$_first" || return 1
    assert_json "recipes.$_place.parameters.mark" "two" || return 1

    run_avm box create "$_box" --image "$_top"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/cat /opt/shtest-note.txt /opt/shtest-mark.txt /opt/shtest-own.txt
    local _output="$OUT"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    for _image in "$_top" "$_mid" "$_first"; do
        "$AGENT_VM" image delete "$_image"
    done
    assert_eq "$_output" $'first note\ntwo\nown' "the rebuilt image" || return 1
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
