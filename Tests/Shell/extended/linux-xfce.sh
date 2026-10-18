#!/bin/bash
#
# Tests/Shell/extended/linux-xfce.sh - the bundled linux-xfce recipe: an image built with
# it records a screen, its boxes start with a display and the box user logged in to XFCE, and
# box view shows the desktop and types into it; image view opens the image. From the ready
# Linux image $AGENT_VM_TEST_LINUX_IMAGE, and only with AGENT_VM_TEST_LINUX_DESKTOP=1: the
# recipe downloads about 94 MB. No signing identity is needed.

test_the_desktop_recipe_gives_a_screen() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    if [ "${AGENT_VM_TEST_LINUX_DESKTOP:-}" != "1" ]; then
        skip "set AGENT_VM_TEST_LINUX_DESKTOP=1 to build an image with the desktop (downloads about 94 MB)"
        return 0
    fi
    local _image="shtest-ldesk-$$"
    local _box="shtest-ldeskbox-$$"
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$TESTS_DIR/../../Recipes/linux-xfce/recipe.json"
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
    # The session started the program that gives the screen an interactive window's size (a
    # moment after xfce4-session itself).
    _waited=0
    while [ "$_waited" -lt 15 ]; do
        run_avm exec --box "$_box" -- /usr/bin/pgrep -u agent -f /usr/local/libexec/agent-vm-fit-display
        [ "$STATUS" -eq 0 ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    assert_status 0 || return 1
    # The wallpaper and many icons are SVG files: without the loader the desktop is black.
    run_avm exec --box "$_box" -- /usr/bin/dpkg-query -W -f '${db:Status-Status}' librsvg2-common
    assert_eq "$OUT" "installed" "the SVG image loader" || return 1

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

    # image view opens the image itself (since 0.8.1). SIGTERM ends it as closing the window
    # does: the image is checked as its build sealed it, and shut down by agent-vm.
    "$AGENT_VM" image view "$_image" --json > "$SCRATCH/view.out" 2> "$SCRATCH/view.err" &
    local _viewer=$!
    _waited=0
    while [ "$_waited" -lt 90 ]; do
        /bin/sleep 1
        _waited=$((_waited + 1))
        case "$(/bin/cat "$SCRATCH/view.err")" in
            *'"step":"window"'*) break ;;
        esac
    done
    /bin/kill -TERM "$_viewer"
    wait "$_viewer"
    local _viewed=$?
    local _events
    _events="$(/bin/cat "$SCRATCH/view.err")"
    printf '%s\n' "$_events"
    assert_eq "$_viewed" "0" "image view's exit status" || return 1
    assert_contains "$_events" '"step":"window"' "image view's events" || return 1
    assert_contains "$_events" "checked: no ssh server" "image view's events" || return 1
    assert_contains "$_events" '"step":"shutdown"' "image view's events" || return 1
    run_avm image info "$_image" --json
    assert_json state ready || return 1
    # A box made of it afterwards still starts with its desktop.
    run_avm box recreate "$_box"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x xfce4-session > /dev/null && exit 0; sleep 1; done; exit 1'
    assert_status 0 || return 1
}
