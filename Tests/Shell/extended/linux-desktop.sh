#!/bin/bash
#
# Tests/Shell/extended/linux-desktop.sh - the bundled linux-desktop recipe: an image built with
# it records a screen, its boxes start with a display and the box user logged in to XFCE, and
# box view shows the desktop and types into it. From the ready Linux image
# $AGENT_VM_TEST_LINUX_IMAGE, and only with AGENT_VM_TEST_LINUX_DESKTOP=1: the recipe downloads
# about 92 MB. No signing identity is needed.

test_the_desktop_recipe_gives_a_screen() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    if [ "${AGENT_VM_TEST_LINUX_DESKTOP:-}" != "1" ]; then
        skip "set AGENT_VM_TEST_LINUX_DESKTOP=1 to build an image with the desktop (downloads about 92 MB)"
        return 0
    fi
    local _image="shtest-ldesk-$$"
    local _box="shtest-ldeskbox-$$"
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$TESTS_DIR/../../Recipes/linux-desktop/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "LightDM starts with the system" || return 1
    assert_out_contains "agent is logged in at start" || return 1
    run_avm image info "$_image" --json
    assert_json screen true || return 1
    # The image this one was made from has none.
    run_avm image info "$LINUX_TEST_IMAGE" --json
    assert_eq "$(json_value screen)" "" "the screen of $LINUX_TEST_IMAGE" || return 1

    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box list --json
    local _screen
    _screen="$(printf '%s' "$OUT" | /usr/bin/jq -r --arg box "$_box" '.[] | select(.box.name == $box) | .box.screen')"
    assert_eq "$_screen" "true" "the box's screen" || return 1
    run_avm box start "$_box" --json
    assert_status 0 || return 1
    # Its supervisor is an application, which can show the screen.
    local _command
    _command="$(/bin/ps -o command= -p "$(json_value pid)")"
    assert_not_contains "$_command" "--headless" "the supervisor's command line" || return 1
    # The box user is logged in to the desktop by itself, on the display.
    local _waited=0
    while [ "$_waited" -lt 30 ]; do
        run_avm exec --box "$_box" -- /usr/bin/pgrep -u agent -x xfce4-session
        [ "$STATUS" -eq 0 ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    assert_status 0 || return 1
    run_avm exec --box "$_box" --user root -- /bin/sh -c 'ls /dev/dri/card0 && loginctl list-sessions --no-legend | grep -c " agent seat0 "'
    assert_status 0 || return 1
    assert_eq "$OUT" $'/dev/dri/card0\n1' "the display and the session" || return 1

    run_avm box view "$_box"
    case "$ERR" in
        *"outside a login session"*)
            skip "the supervisor runs outside a login session"
            return 0
            ;;
    esac
    assert_status 0 || return 1
    assert_out_contains "view only" || return 1
    # The account has no password to type.
    run_avm box view "$_box" --type-password
    assert_status 1 || return 1
    assert_err_contains "box $_box runs Linux, whose account has no password to type" || return 1
    # Keys reach the desktop: a line typed into a terminal on it is read there. The terminal runs
    # a reader that says when it has started (a first start can take seconds), and the line is
    # typed only then.
    run_avm exec --box "$_box" -- /bin/sh -c 'rm -f /tmp/started /tmp/typed; printf "#!/bin/sh\necho started > /tmp/started\nIFS= read -r line\nprintf \"%%s\" \"\$line\" > /tmp/typed\n" > /tmp/reader; chmod 755 /tmp/reader; DISPLAY=:0 XAUTHORITY=$HOME/.Xauthority setsid -f xfce4-terminal --disable-server -x /tmp/reader > /dev/null 2>&1'
    assert_status 0 || return 1
    _waited=0
    while [ "$_waited" -lt 30 ]; do
        run_avm exec --box "$_box" -- /usr/bin/test -f /tmp/started
        [ "$STATUS" -eq 0 ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    assert_status 0 || return 1
    /bin/sleep 1
    run_avm box view "$_box" --type $'Typed-OK_42 x/y.z >AB\r'
    assert_status 0 || return 1
    _waited=0
    while [ "$_waited" -lt 10 ]; do
        run_avm exec --box "$_box" -- /bin/cat /tmp/typed
        [ "$STATUS" -eq 0 ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    assert_eq "$OUT" "Typed-OK_42 x/y.z >AB" "what was typed into the terminal" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
}
