#!/bin/bash
#
# Tests/Shell/extended/images.sh - building images: a derived image with a small recipe (about
# a minute), a failing recipe, and - only when $AGENT_VM_TEST_IPSW names a restore image - a
# full install from scratch (about 6 minutes, about 30 GB while it exists).

# write_recipe <folder> <json>
write_recipe() {
    /bin/mkdir -p "$1/files"
    printf '%s\n' "$2" > "$1/recipe.json"
}

test_derived_image_with_a_recipe() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-img-$$"
    local _box="shtest-imgbox-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{
      "version": 1,
      "description": "shell test",
      "steps": [
        { "name": "tool", "user": "root", "copy": "files/hello", "to": "/usr/local/bin/shtest-hello", "mode": "0755" },
        { "name": "note", "run": "echo \"built for $AGENT_VM_BOX_USER\" > ~/shtest-note.txt" }
      ],
      "checks": ["shtest-hello", "cat ~/shtest-note.txt"]
    }'
    printf '#!/bin/sh\necho hello from the image\n' > "$SCRATCH/recipe/files/hello"

    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "check shtest-hello: hello from the image" || return 1
    run_avm image list
    assert_out_contains "$_image  ready" || return 1
    assert_out_contains "from \"$TEST_IMAGE\" image  recipe shell test" || return 1

    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'shtest-hello; cat ~/shtest-note.txt'
    local _output="$OUT"
    local _status="$STATUS"
    "$AGENT_VM" box stop "$_box"
    "$AGENT_VM" box delete "$_box"
    "$AGENT_VM" image delete "$_image"
    [ "$_status" -eq 0 ] || { fail "exec in the derived image's box failed ($_status)"; return 1; }
    assert_eq "$_output" $'hello from the image\nbuilt for agent' "the recipe's work" || return 1
}

# Two recipes in one image, in the order given, sharing a parameter; the image keeps each
# recipe with the files it copies, and an image built from it lists them as inherited.
test_several_recipes_in_one_image() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-multi-$$"
    local _child="shtest-multichild-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    "$AGENT_VM" image delete "$_child" > /dev/null 2>&1
    cleanup_on_exit image "$_child"
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/first" '{
      "version": 1,
      "description": "first tools",
      "parameters": {"who": {"default": "nobody"}},
      "steps": [
        { "name": "tool", "user": "root", "copy": "files/hello", "to": "/usr/local/bin/shtest-hello", "mode": "0755" },
        { "name": "note", "run": "echo \"first for $AGENT_VM_PARAM_WHO\" > ~/shtest-order.txt" }
      ],
      "checks": ["shtest-hello"]
    }'
    printf '#!/bin/sh\necho hello from the image\n' > "$SCRATCH/first/files/hello"
    write_recipe "$SCRATCH/second" '{
      "version": 1,
      "description": "second tools",
      "parameters": {"who": {"default": "nobody"}},
      "steps": [{ "name": "note", "run": "shtest-hello > /dev/null && echo \"second for $AGENT_VM_PARAM_WHO\" >> ~/shtest-order.txt" }],
      "checks": ["cat ~/shtest-order.txt | tr \"\\n\" \",\""]
    }'

    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/first/recipe.json" --recipe "$SCRATCH/second/recipe.json" --set who=tests
    assert_status 0 || return 1
    assert_out_contains "Recipe 1 of 2: first tools" || return 1
    assert_out_contains "Recipe 2 of 2: second tools" || return 1
    assert_out_contains "first for tests,second for tests," || return 1
    run_avm image list
    assert_out_contains "from \"$TEST_IMAGE\" image  recipes first, second [who=tests]" || return 1
    run_avm image info "$_image" --json
    assert_json recipes.0.name "first" || return 1
    assert_json recipes.1.name "second" || return 1
    assert_json recipes.1.folder "2-second" || return 1
    assert_json recipe.description "first tools; second tools" || return 1
    local _folder
    _folder="$(json_value path)"
    assert_exists "$_folder/Recipes/1-first/recipe.json" || return 1
    assert_exists "$_folder/Recipes/1-first/files/hello" || return 1
    assert_exists "$_folder/Recipes/2-second/recipe.json" || return 1
    assert_missing "$_folder/recipe.json" || return 1

    write_recipe "$SCRATCH/third" '{"version": 1, "description": "third tools", "steps": [{"run": "echo third >> ~/shtest-order.txt"}]}'
    run_avm image create "$_child" --from "$_image" --recipe "$SCRATCH/third/recipe.json"
    assert_status 0 || return 1
    run_avm image info "$_child" --json
    assert_json recipes.0.inheritedFrom "$_image" || return 1
    assert_json recipes.1.inheritedFrom "$_image" || return 1
    assert_json recipes.2.name "third" || return 1
    assert_json recipes.2.inheritedFrom "" || return 1
    assert_json recipe.description "third tools" || return 1
    _folder="$(json_value path)"
    assert_exists "$_folder/Recipes/1-first/files/hello" || return 1
    assert_exists "$_folder/Recipes/3-third/recipe.json" || return 1
    assert_exists "$_folder/recipe.json" || return 1
    "$AGENT_VM" image delete "$_child"
    "$AGENT_VM" image delete "$_image"
}

test_a_failing_recipe_marks_the_image_failed() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-bad-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "steps": [{"name": "breaks", "run": "echo about to fail; exit 3"}]}'
    # With --json, progress comes as events on stderr, the step's output among them.
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --json
    assert_status 1 || return 1
    assert_err_contains "recipe step 1 (breaks)" || return 1
    assert_err_events || return 1
    assert_err_contains '"step":"clone"' || return 1
    assert_err_contains '{"count":1,"event":"progress","fraction":0,"image":"'"$_image"'","index":1,"message":"[1/1] breaks","step":"recipe-step"}' || return 1
    assert_err_contains '{"event":"log","image":"'"$_image"'","message":"about to fail","output":true}' || return 1
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# A copy step whose program fails before reading its input (the box account cannot make a folder
# in /Library): the build reports the program's own error, not the write that found the
# connection closed ("Broken pipe").
test_a_step_failing_before_its_input_reports_its_own_error() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-early-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "steps": [{"name": "blocked", "copy": "files/big", "to": "/Library/shtest-blocked/big"}]}'
    # Far more than the connection holds, so sending is under way when the program ends.
    /bin/dd if=/dev/zero of="$SCRATCH/recipe/files/big" bs=1048576 count=16 2> /dev/null
    local _made=$?
    [ "$_made" -eq 0 ] || { fail "cannot make the 16 MB test file (dd status $_made)"; return 1; }
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "recipe step 1 (blocked)" || return 1
    assert_err_contains "Permission denied" || return 1
    assert_not_contains "$ERR" "Broken pipe" "the error" || return 1
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# SIGINT during a recipe step: the step is stopped, the guest shut down through its daemon, the
# image marked failed with "canceled", and agent-vm exits with 128 + 2.
test_a_canceled_build_is_marked_canceled() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-cancel-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "steps": [{"name": "long", "run": "echo sleeping; sleep 300"}]}'
    "$AGENT_VM" image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json" --json \
        > "$SCRATCH/create.out" 2> "$SCRATCH/create.err" &
    local _pid=$!
    wait_for_text "$SCRATCH/create.err" '"message":"sleeping"' 180
    local _reached=$?
    kill -INT "$_pid"
    local _began
    _began="$(/bin/date +%s)"
    wait "$_pid"
    STATUS=$?
    local _took=$(( $(/bin/date +%s) - _began ))
    ERR="$(/bin/cat "$SCRATCH/create.err")"
    printf '%s\n[status %s after %s s]\n' "$ERR" "$STATUS" "$_took"
    [ "$_reached" -eq 0 ] || { fail "the recipe step did not start within 180 s"; return 1; }
    assert_status 130 || return 1
    assert_err_events || return 1
    assert_err_contains '"message":"Canceled; shutting down","step":"shutdown"' || return 1
    assert_err_contains "is marked failed (canceled): canceled by SIGINT" || return 1
    assert_not_contains "$ERR" "did not shut down" "stderr" || return 1
    [ "$_took" -lt 60 ] || { fail "the cancel took $_took s"; return 1; }
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
    assert_eq "$(image_value "$_image" failure)" "canceled" "the image's failure" || return 1
    [ ! -s "$SCRATCH/create.out" ] || { fail "stdout is not empty"; return 1; }
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# SIGTERM while a guest update boots, before the daemon is touched: the guest shuts down cleanly
# once its daemon answers, the image stays ready, the images after it are skipped, and
# agent-vm exits with 128 + 15.
test_a_canceled_guest_update_leaves_the_image_ready() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-upd-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "steps": [{"name": "nothing", "run": "true"}]}'
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1

    "$AGENT_VM" image update-guest "$_image" "$TEST_IMAGE" > "$SCRATCH/update.out" 2> "$SCRATCH/update.err" &
    local _pid=$!
    wait_for_text "$SCRATCH/update.out" "Booting $_image" 60
    local _reached=$?
    kill -TERM "$_pid"
    wait "$_pid"
    STATUS=$?
    ERR="$(/bin/cat "$SCRATCH/update.err")"
    printf '%s\n%s\n[status %s]\n' "$(/bin/cat "$SCRATCH/update.out")" "$ERR" "$STATUS"
    [ "$_reached" -eq 0 ] || { fail "the update did not boot the image within 60 s"; return 1; }
    assert_status 143 || return 1
    # Canceled while booting: the guest is given the time to answer and shuts down cleanly.
    local _out
    _out="$(/bin/cat "$SCRATCH/update.out")"
    assert_contains "$_out" "Canceled; shutting down" "stdout" || return 1
    assert_not_contains "$_out" "did not shut down" "stdout" || return 1
    assert_err_contains "Image $_image is unchanged: canceled by SIGTERM" || return 1
    assert_err_contains "Canceled at image $_image; not updated: $TEST_IMAGE" || return 1
    assert_eq "$(image_state "$_image")" "ready" "the image's state" || return 1
    assert_eq "$(image_state "$TEST_IMAGE")" "ready" "the skipped image's state" || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

test_full_install_from_a_restore_image() {
    if [ -z "${AGENT_VM_TEST_IPSW:-}" ]; then
        skip "set AGENT_VM_TEST_IPSW to a restore image to run it"
        return 0
    fi
    local _image="shtest-full-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    run_avm image create "$_image" --ipsw "$AGENT_VM_TEST_IPSW" --no-command-line-tools
    local _status="$STATUS"
    local _state
    _state="$(image_state "$_image")"
    "$AGENT_VM" image delete "$_image"
    [ "$_status" -eq 0 ] || { fail "image create failed ($_status)"; return 1; }
    assert_eq "$_state" "ready" "the new image" || return 1
}
