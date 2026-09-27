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
