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
    assert_out_contains "from $TEST_IMAGE  recipe shell test" || return 1

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

test_a_failing_recipe_marks_the_image_failed() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _image="shtest-bad-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    write_recipe "$SCRATCH/recipe" '{"version": 1, "steps": [{"name": "breaks", "run": "echo about to fail; exit 3"}]}'
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "recipe step 1 (breaks)" || return 1
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
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
