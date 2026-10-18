#!/bin/bash
#
# Tests/Shell/extended/linux-desktops.sh - the bundled linux-gnome and linux-kde recipes: an
# image built with each records a screen and keeps polkitd with the rules that refuse; its boxes
# start with the box user logged in to the desktop on Wayland, nothing listens for the network,
# polkitd refuses the box user (also through its user manager, where Debian's rules would let it
# act as the desktop's user), the screen does not stay locked, and image view's seal check passes
# with polkitd. The GNOME test also turns polkit=debian on and back off with image update. From
# the ready Linux image $AGENT_VM_TEST_LINUX_IMAGE, and only with AGENT_VM_TEST_LINUX_DESKTOP=1:
# the recipes download about 210 and 340 MB.

# What polkitd answers the box user about powering the box off, asked from the box user's own
# manager, as a desktop's applications are: 0 allowed, 1 refused, 2 a password needed. In OUT.
polkit_answer_in_session() {
    local _box="$1"
    run_avm exec --box "$_box" -- /bin/sh -c 'printf "%s\n" "#!/bin/sh" "/usr/bin/pkcheck --action-id org.freedesktop.login1.power-off --process \$\$ > /dev/null 2>&1; echo \$?" > /tmp/pkcheck.sh && chmod 755 /tmp/pkcheck.sh && XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus systemd-run --user --quiet --wait --pipe /tmp/pkcheck.sh'
}

# Opens image $1 with image view and ends it as closing the window does: the seal checks run,
# the polkitd one among them, and the image must stay ready.
view_and_check_seal() {
    local _image="$1"
    "$AGENT_VM" image view "$_image" --json > "$SCRATCH/view.out" 2> "$SCRATCH/view.err" &
    local _viewer=$!
    local _waited=0
    while [ "$_waited" -lt 120 ]; do
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
    assert_eq "$_viewed" "0" "image view's exit status" || return 1
    assert_contains "$_events" "polkitd is gone, or has the rules a desktop's recipe chose" "image view's events" || return 1
    run_avm image info "$_image" --json
    assert_json state ready || return 1
}

# Builds an image of $LINUX_TEST_IMAGE with Recipes/$1, starts a box of it and checks what both
# recipes promise. $2 is the desktop's shell process, $3 its login manager as the build names it,
# $4 "unlocks" when a lock asked of the system holds until root unlocks it (Plasma) and "never"
# when the desktop does not lock (GNOME), $5 and $6 the names of the image and the box, which
# are left for the caller.
check_desktop() {
    local _recipe="$1"
    local _shell="$2"
    local _manager="$3"
    local _lock="$4"
    local _image="$5"
    local _box="$6"
    run_avm image create "$_image" --from "$LINUX_TEST_IMAGE" --recipe "$TESTS_DIR/../../Recipes/$_recipe/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "$_manager starts with the system" || return 1
    assert_out_contains "agent is logged in" || return 1
    assert_out_contains "polkitd refuses every request (polkit=deny)" || return 1
    run_avm image info "$_image" --json
    assert_json screen true || return 1

    # A box with a desktop under 4 GB is noted as small, though 2 GB is no note without one.
    run_avm box create "$_box" --image "$_image" --memory-gb 2
    assert_status 0 || return 1
    assert_err_contains "with a desktop has little of it free and no swap" || return 1
    run_avm box set "$_box" --memory-gb 4
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    local _waited=0
    while [ "$_waited" -lt 60 ]; do
        run_avm exec --box "$_box" -- /usr/bin/pgrep -u agent -x "$_shell"
        [ "$STATUS" -eq 0 ] && break
        /bin/sleep 1
        _waited=$((_waited + 1))
    done
    assert_status 0 || return 1
    # The box user's session is on the display, on Wayland.
    run_avm exec --box "$_box" --user root -- /bin/sh -c 'session="$(loginctl list-sessions --no-legend | awk "\$3 == \"agent\" && \$4 == \"seat0\" {print \$1}")"; loginctl show-session "$session" -P Type'
    assert_status 0 || return 1
    assert_eq "$OUT" "wayland" "the session's type" || return 1
    # Nothing listens for the network, with the desktop's services running.
    run_avm exec --box "$_box" --user root -- /bin/sh -c "ss -H -l -t -u -n | grep -v -E '[[:space:]](127\\.[0-9.]+(%lo)?|\\[::1\\]):[0-9]+[[:space:]]'"
    assert_eq "$OUT" "" "listeners beyond the box itself" || return 1
    # polkitd refuses the box user, from exec and from its manager.
    run_avm exec --box "$_box" -- /bin/sh -c '/usr/bin/pkcheck --action-id org.freedesktop.login1.power-off --process $$ > /dev/null 2>&1; echo $?'
    assert_eq "$OUT" "1" "polkitd's answer to exec" || return 1
    polkit_answer_in_session "$_box"
    assert_status 0 || return 1
    assert_eq "$OUT" "1" "polkitd's answer in the box user's manager" || return 1

    # A lock asked of the system: GNOME does not lock; Plasma does, and root unlocks it.
    run_avm exec --box "$_box" --user root -- /bin/sh -c 'session="$(loginctl list-sessions --no-legend | awk "\$3 == \"agent\" && \$4 == \"seat0\" {print \$1}")"; loginctl lock-session "$session"; sleep 4; loginctl show-session "$session" -P LockedHint'
    if [ "$_lock" = "never" ]; then
        assert_eq "$OUT" "no" "the session after a lock" || return 1
    else
        assert_eq "$OUT" "yes" "the session after a lock" || return 1
        run_avm exec --box "$_box" --user root -- /bin/sh -c 'loginctl unlock-sessions; sleep 2; session="$(loginctl list-sessions --no-legend | awk "\$3 == \"agent\" && \$4 == \"seat0\" {print \$1}")"; loginctl show-session "$session" -P LockedHint'
        assert_eq "$OUT" "no" "the session after unlock-sessions" || return 1
    fi

    run_avm box view "$_box"
    case "$ERR" in
        *"outside a login session"*)
            skip "the supervisor runs outside a login session"
            return 0
            ;;
    esac
    assert_status 0 || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1

    # image view's seal check accepts polkitd with the refusing rule.
    view_and_check_seal "$_image" || return 1
}

test_the_gnome_recipe_gives_a_screen_and_a_polkit_choice() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    if [ "${AGENT_VM_TEST_LINUX_DESKTOP:-}" != "1" ]; then
        skip "set AGENT_VM_TEST_LINUX_DESKTOP=1 to build an image with GNOME (downloads about 210 MB)"
        return 0
    fi
    local _image="shtest-lgnome-$$"
    local _box="shtest-lgnomebox-$$"
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    check_desktop linux-gnome gnome-shell GDM never "$_image" "$_box" || return 1

    # Debian's rules: the box user's manager may power the box off; the image keeps the choice.
    run_avm image update "$_image" --tools --set polkit=debian
    assert_status 0 || return 1
    assert_out_contains "polkitd follows Debian's rules (polkit=debian)" || return 1
    run_avm box recreate "$_box"
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'for i in $(seq 1 60); do pgrep -x gnome-shell > /dev/null && exit 0; sleep 1; done; exit 1'
    assert_status 0 || return 1
    polkit_answer_in_session "$_box"
    assert_eq "$OUT" "0" "polkitd's answer in the box user's manager, with Debian's rules" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
    # The seal check takes Debian's rules as they are: the marker alone, and packages' rules files.
    view_and_check_seal "$_image" || return 1
    # And back.
    run_avm image update "$_image" --tools --set polkit=deny
    assert_status 0 || return 1
    assert_out_contains "polkitd refuses every request (polkit=deny)" || return 1
    # A value the recipe does not know fails the update, which keeps nothing of it.
    run_avm image update "$_image" --tools --set polkit=yes
    assert_status 1 || return 1
    assert_err_contains "the polkit parameter is deny or debian, not 'yes'" || return 1
}

test_the_kde_recipe_gives_a_screen() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    if [ "${AGENT_VM_TEST_LINUX_DESKTOP:-}" != "1" ]; then
        skip "set AGENT_VM_TEST_LINUX_DESKTOP=1 to build an image with KDE Plasma (downloads about 340 MB)"
        return 0
    fi
    local _image="shtest-lkde-$$"
    local _box="shtest-lkdebox-$$"
    cleanup_on_exit box "$_box"
    cleanup_on_exit image "$_image"
    check_desktop linux-kde plasmashell SDDM unlocks "$_image" "$_box" || return 1
}
