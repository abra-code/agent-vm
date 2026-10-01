#!/bin/bash
#
# Tests/Shell/extended/connect-new.sh - avm new, on real boxes from $TEST_IMAGE: a temporary box
# lives exactly as long as its session, a kept box stays (with no owner), and a temporary box
# whose avm is killed is stopped by its owner lease and then collected. Each test makes its own
# box, one at a time; script(1) provides the terminal (on_terminal).

# created_box <file>: the box named in a "Creating box <name> from ..." line of <file> (not
# anchored: script(1) may echo a ^D in front of it).
created_box() {
    /usr/bin/sed -n 's/.*Creating box \([^ ]*\) from .*/\1/p' "$1" | /usr/bin/head -n 1
}

test_connect_new_temporary_box_lives_as_long_as_the_session() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    on_terminal ':' "$SCRATCH/avm" new "$TEST_IMAGE" --no-project -- /bin/echo inside
    printf '%s\n' "$OUT" > "$SCRATCH/avm.out"
    local _name
    _name="$(created_box "$SCRATCH/avm.out")"
    [ -n "$_name" ] && cleanup_on_exit box "$_name"
    assert_status 0 || return 1
    assert_out_contains "(temporary: deleted when you leave)" || return 1
    assert_out_contains "inside" || return 1
    assert_out_contains "Stopping box $_name (temporary)" || return 1
    assert_out_contains "stopped and deleted" || return 1
    assert_not_contains "$OUT" "keeps running" "the output" || return 1
    run_avm box status "$_name"
    assert_status 1 || return 1
    assert_err_contains "no box $_name" || return 1
}

# --refresh updates the image's tools (its recipes' update steps) before the box is made: the
# box holds what the update wrote, the image's revision moved, and each step was shown.
test_connect_new_refresh_updates_the_image_first() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    local _image="shtest-refresh-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    /bin/mkdir -p "$SCRATCH/recipe"
    printf '%s\n' '{
      "version": 1,
      "description": "refresh test",
      "steps": [{ "name": "note", "run": "echo built > ~/shtest-refresh.txt" }],
      "update": [{ "name": "note again", "run": "echo refreshed >> ~/shtest-refresh.txt" }],
      "checks": ["wc -l < ~/shtest-refresh.txt"]
    }' > "$SCRATCH/recipe/recipe.json"
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1

    on_terminal ':' "$SCRATCH/avm" new "$_image" --refresh --no-project -- /bin/cat shtest-refresh.txt
    printf '%s\n' "$OUT" > "$SCRATCH/avm.out"
    local _name
    _name="$(created_box "$SCRATCH/avm.out")"
    [ -n "$_name" ] && cleanup_on_exit box "$_name"
    assert_status 0 || return 1
    assert_out_contains "Updated the tools of $_image (" || return 1
    assert_out_contains "refreshed" || return 1
    # The update came before the box.
    local _order
    _order="$(/usr/bin/grep -n -e "Updated the tools of" -e "Creating box" "$SCRATCH/avm.out" | /usr/bin/head -n 1)"
    assert_contains "$_order" "Updated the tools of" "the first of the two lines" || return 1
    run_avm image info "$_image" --json
    assert_json revision "1" || return 1
    "$AGENT_VM" image delete "$_image"
}

# Control-C during --refresh cancels the update cleanly: its virtual machine is shut down, the
# image is as it was, and no box is made.
test_connect_new_refresh_is_canceled_cleanly() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    local _image="shtest-refreshc-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    /bin/mkdir -p "$SCRATCH/recipe"
    printf '%s\n' '{"version": 1, "steps": [{"run": "true"}], "update": [{"name": "slow", "run": "sleep 120"}]}' > "$SCRATCH/recipe/recipe.json"
    run_avm image create "$_image" --from "$TEST_IMAGE" --recipe "$SCRATCH/recipe/recipe.json"
    assert_status 0 || return 1

    # The terminal's interrupt character, once the update is in its slow step.
    on_terminal '/bin/sleep 45; printf "\003"; /bin/sleep 30' "$SCRATCH/avm" new "$_image" --refresh --no-project -- /usr/bin/true
    assert_status 130 || return 1
    assert_out_contains "Updating the tools of $_image was canceled" || return 1
    assert_out_contains "the image is as it was, and no box was made" || return 1
    assert_not_contains "$OUT" "Creating box" "the output" || return 1
    run_avm image info "$_image" --json
    assert_json state "ready" || return 1
    assert_json revision "" || return 1
    local _folder
    _folder="$(json_value path)"
    assert_missing "$_folder/Update" || return 1
    # The update's virtual machine is gone, not left running.
    run_avm image update "$_image" --guest
    assert_status 0 || return 1
    "$AGENT_VM" image delete "$_image"
}

test_connect_new_kept_box_stays() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    local _name="shtest-kept-$$"
    cleanup_on_exit box "$_name"
    on_terminal ':' "$SCRATCH/avm" new "$TEST_IMAGE" --name "$_name" --no-project -- /usr/bin/true
    assert_status 0 || return 1
    assert_out_contains "Creating box $_name from $TEST_IMAGE" || return 1
    assert_out_contains "Box $_name keeps running" || return 1
    run_avm box status "$_name" --json
    assert_json state running || return 1
    [ -z "$(json_value ownerPid)" ] || { fail "the kept box has an owner: $(json_value ownerPid)"; return 1; }
}

test_connect_killed_stops_its_temporary_box() {
    require_image || return $(( $? == 1 ? 0 : 1 ))
    avm_link || return 1
    /usr/bin/script -q /dev/null "$SCRATCH/avm" new "$TEST_IMAGE" --no-project -- /bin/sleep 120 > "$SCRATCH/avm.out" 2>&1 &
    local _script=$!
    wait_for_text "$SCRATCH/avm.out" "Creating box" 60 || { kill "$_script" 2>/dev/null; fail "no Creating box line"; return 1; }
    local _name
    _name="$(created_box "$SCRATCH/avm.out" | /usr/bin/tr -d '\r')"
    cleanup_on_exit box "$_name"
    wait_for_text "$SCRATCH/avm.out" "in box $_name" 180 || { kill "$_script" 2>/dev/null; fail "the session did not start"; return 1; }
    run_avm box status "$_name" --json
    local _owner
    _owner="$(json_value ownerPid)"
    [ -n "$_owner" ] || { kill "$_script" 2>/dev/null; fail "the temporary box has no owner"; return 1; }
    # The owner is avm itself: the process id agent-vm recorded, never a name match.
    kill -KILL "$_owner"
    local _waited=0
    local _state
    while [ "$_waited" -lt 60 ]; do
        run_avm box status "$_name" --json > /dev/null
        _state="$(json_value state)"
        [ "$STATUS" -ne 0 ] || [ "$_state" = "stopped" ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    kill "$_script" 2>/dev/null
    wait "$_script" 2>/dev/null
    [ "$_waited" -lt 60 ] || { fail "box $_name did not stop within 60 s of its owner's end"; return 1; }
    run_avm box gc
    run_avm box status "$_name"
    assert_status 1 || return 1
    assert_err_contains "no box $_name" || return 1
}
