#!/bin/bash
#
# Tests/Shell/extended/linux-boxes.sh - Linux boxes: start and stop in seconds, several at once
# (the limit of two is for macOS guests), what a Linux box has no meaning for, and the console
# log's bounds. From the ready Linux image $AGENT_VM_TEST_LINUX_IMAGE; without it every test
# is skipped. No signing identity is needed.

# seconds_since <epoch seconds>
seconds_since() {
    printf '%s' "$(( $(/bin/date +%s) - $1 ))"
}

test_linux_box_starts_and_stops_in_seconds() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lbox-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    local _began
    _began="$(/bin/date +%s)"
    run_avm box start "$_box" --json
    assert_status 0 || return 1
    local _took
    _took="$(seconds_since "$_began")"
    [ "$_took" -lt 20 ] || { fail "the start took $_took s"; return 1; }
    assert_err_events || return 1
    run_avm box status "$_box" --json
    assert_json state running || return 1
    assert_json guest linux || return 1
    assert_json guestFeatures.0 terminal || return 1
    local _log
    _log="$(box_folder "$_box")/supervisor.log"
    assert_contains "$(/bin/cat "$_log")" "Ready in" "the supervisor's log" || return 1
    assert_contains "$(/bin/cat "$_log")" "(no network card, proxy on vsock port 3128)" "the supervisor's log" || return 1
    # Its supervisor is no application: it was told the box has no screen.
    local _pid
    _pid="$(json_value pid)"
    local _command
    _command="$(/bin/ps -o command= -p "$_pid")"
    assert_contains "$_command" "box serve $_box --headless" "the supervisor's command line" || return 1
    # The console's output is kept, and small.
    local _console
    _console="$(box_folder "$_box")/console.log"
    assert_exists "$_console" || return 1
    [ "$(/usr/bin/stat -f %z "$_console")" -gt 1000 ] || { fail "console.log holds almost nothing"; return 1; }
    [ "$(/usr/bin/stat -f %Lp "$_console")" = "600" ] || { fail "console.log is not private"; return 1; }
    run_avm status --json
    assert_json runningVMs.linuxBoxes 1 || return 1

    _began="$(/bin/date +%s)"
    run_avm box stop "$_box"
    assert_status 0 || return 1
    _took="$(seconds_since "$_began")"
    [ "$_took" -lt 20 ] || { fail "the stop took $_took s"; return 1; }
    assert_contains "$(/bin/cat "$_log")" "Stopped" "the supervisor's log" || return 1
    assert_not_contains "$(/bin/cat "$_log")" "pulling the plug" "the supervisor's log" || return 1
    assert_not_contains "$(/bin/cat "$_log")" "power button" "the supervisor's log" || return 1
    run_avm status --json
    assert_json runningVMs.linuxBoxes 0 || return 1
    # A second start of the same disk: its own machine id, and what was written stays.
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /usr/bin/test -s /etc/machine-id
    assert_status 0 || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
    run_avm box delete "$_box"
    assert_status 0 || return 1
}

# Three Linux boxes at once, each with a machine id of its own; with $AGENT_VM_TEST_IMAGE ready
# and two places free, beside two macOS boxes too.
test_three_linux_boxes_at_once() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _name
    local _ids=""
    for _name in a b c; do
        cleanup_on_exit box "shtest-l3$_name-$$"
        run_avm box create "shtest-l3$_name-$$" --image "$LINUX_TEST_IMAGE"
        assert_status 0 || return 1
    done
    for _name in a b c; do
        run_avm box start "shtest-l3$_name-$$"
        assert_status 0 || return 1
    done
    for _name in a b c; do
        run_avm exec --box "shtest-l3$_name-$$" -- /usr/bin/cat /etc/machine-id
        assert_status 0 || return 1
        _ids="$_ids $OUT"
    done
    local _distinct
    _distinct="$(printf '%s\n' $_ids | /usr/bin/sort -u | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    assert_eq "$_distinct" "3" "machine ids of three boxes of one image" || return 1
    run_avm status --json
    assert_json runningVMs.linuxBoxes 3 || return 1
    run_avm doctor --json
    assert_json checks.7.name "running VMs" || return 1
    assert_json checks.7.linuxBoxes 3 || return 1
    for _name in a b c; do
        run_avm box stop "shtest-l3$_name-$$"
        assert_status 0 || return 1
        run_avm box delete "shtest-l3$_name-$$"
        assert_status 0 || return 1
    done
}

# The limit of two is for macOS guests: with two macOS boxes running, a Linux box still starts.
test_a_linux_box_beside_two_macos_boxes() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    require_image || return $(( $? == 1 ? 0 : 1 ))
    local _name
    for _name in m1 m2; do
        cleanup_on_exit box "shtest-l$_name-$$"
        run_avm box create "shtest-l$_name-$$" --image "$TEST_IMAGE"
        assert_status 0 || return 1
        run_avm box start "shtest-l$_name-$$"
        if [ "$STATUS" -ne 0 ]; then
            skip "two macOS boxes could not be started here (another virtual machine runs?)"
            return 0
        fi
    done
    local _box="shtest-lbeside-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /usr/bin/uname -s
    assert_eq "$OUT" "Linux" "the third machine" || return 1
    run_avm status --json
    assert_json runningVMs.linuxBoxes 1 || return 1
    assert_json runningVMs.count 3 || return 1
    run_avm doctor --json
    assert_json checks.7.status warning || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
}

test_a_linux_box_stops_when_its_owner_exits() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lowner-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    /bin/sleep 600 &
    local _owner=$!
    run_avm box start "$_box" --owner-pid "$_owner"
    assert_status 0 || return 1
    kill "$_owner"
    wait "$_owner" 2>/dev/null
    local _waited=0
    local _state="running"
    while [ "$_waited" -lt 30 ] && [ "$_state" != "stopped" ]; do
        /bin/sleep 1
        _waited=$((_waited + 1))
        _state="$("$AGENT_VM" box status "$_box" --json | /usr/bin/jq -r .state)"
    done
    assert_eq "$_state" "stopped" "the box's state after its owner exited" || return 1
    assert_contains "$(/bin/cat "$(box_folder "$_box")/supervisor.log")" "The owner process $_owner exited; stopping" "the supervisor's log" || return 1
}

# What a Linux box has no meaning for is refused by the command; the box goes on running.
test_view_is_refused() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lrefuse-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm box view "$_box"
    assert_status 1 || return 1
    assert_err_contains "box $_box runs Linux without a desktop, so it has no screen to show (an image built with a desktop recipe, such as linux-xfce, has one); open a shell with" || return 1
    run_avm exec --box "$_box" -- /usr/bin/id -un
    assert_eq "$OUT" "agent" "the box after the refusal" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
}

# A guest that prints without end fills two files of a megabyte and no more, and the box goes
# on answering.
test_the_console_log_stays_small() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lconsole-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" --user root -- /usr/bin/timeout 5 /bin/sh -c 'yes 0123456789012345678901234567890123456789012345678901234567890123456789 > /dev/console'
    assert_status 124 || return 1
    local _folder
    _folder="$(box_folder "$_box")"
    # A file that is not there counts as empty: an empty operand would end the whole run.
    local _current
    _current="$(/usr/bin/stat -f %z "$_folder/console.log" 2>/dev/null)"
    local _previous
    _previous="$(/usr/bin/stat -f %z "$_folder/console.log.1" 2>/dev/null)"
    local _size=$(( ${_current:-0} + ${_previous:-0} ))
    [ "$_size" -le 3145728 ] || { fail "the console's two files hold $_size bytes"; return 1; }
    [ "$_size" -ge 1048576 ] || { fail "the console's files hold only $_size bytes: the flood did not reach them"; return 1; }
    assert_missing "$_folder/console.log.2" || return 1
    run_avm exec --box "$_box" -- /usr/bin/id -un
    assert_eq "$OUT" "agent" "the box after the flood" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
}
