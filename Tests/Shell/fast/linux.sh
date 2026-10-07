#!/bin/bash
#
# Tests/Shell/fast/linux.sh - image create --linux: what is refused before anything is
# downloaded or booted (the choice of a source, the release, the Linux guest daemon, the
# account's name, the disk's size).

test_image_create_wants_one_source() {
    run_avm image create x --linux debian-13 --ipsw /nowhere.ipsw
    assert_status 64 || return 1
    assert_err_contains "give one of --ipsw (install macOS), --linux (a Linux cloud image) or --from (start from a ready image)" || return 1
    run_avm image create x --linux debian-13 --from dev --recipe r.json
    assert_status 64 || return 1
    assert_err_contains "give one of --ipsw" || return 1
}

test_cloud_image_needs_linux() {
    run_avm image create x --ipsw /nowhere.ipsw --cloud-image /nowhere.tar.xz
    assert_status 64 || return 1
    assert_err_contains "--cloud-image is a Linux cloud image: give --linux <release> with it" || return 1
}

test_linux_release_must_be_known() {
    run_avm image create x --linux nope
    assert_status 1 || return 1
    assert_err_contains "--linux nope: this agent-vm knows debian-13 (debian means the newest)" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
    assert_missing "$AGENT_VM_HOME/Cache" || return 1
}

# Without the Linux daemon nothing is downloaded and nothing is created; a Mac program in its
# place is no Linux daemon either.
test_linux_create_needs_the_linux_daemon() {
    run_avm image create x --linux debian-13 --guest-daemon /nonexistent/agent-vm-guest
    assert_status 1 || return 1
    assert_err_contains "the Linux guest daemon /nonexistent/agent-vm-guest is missing or not a Linux program" || return 1
    assert_err_contains "Scripts/build.sh builds it when the swift.org toolchain and its static Linux SDK are installed" || return 1
    run_avm image create x --linux debian --guest-daemon "$(/usr/bin/dirname "$AGENT_VM")/agent-vm-guest"
    assert_status 1 || return 1
    assert_err_contains "is missing or not a Linux program" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
    assert_missing "$AGENT_VM_HOME/Cache" || return 1
}

test_linux_create_checks_the_account_and_the_disk() {
    # Names a Linux system has for itself are not the box user's to take.
    run_avm image create x --linux debian-13 --user sudo
    assert_status 1 || return 1
    assert_err_contains "sudo is not a usable account name" || return 1
    run_avm image create x --linux debian-13 --user systemd-box
    assert_status 1 || return 1
    run_avm image create x --linux debian-13 --disk-gb 4
    assert_status 1 || return 1
    assert_err_contains "4 GB is too small; a Linux image needs at least 8 GB" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

# A cloud image of one's own must exist and be an archive or a raw disk; it is looked at before
# an image is created.
test_a_cloud_image_of_ones_own_is_looked_at_first() {
    local _linux
    _linux="$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest"
    if [ ! -x "$_linux" ]; then
        skip "this build has no linux/agent-vm-guest"
        return 0
    fi
    run_avm image create x --linux debian-13 --cloud-image "$SCRATCH/none.tar.xz"
    assert_status 1 || return 1
    assert_err_contains "--cloud-image $SCRATCH/none.tar.xz: no such file" || return 1
    printf 'not a disk\n' > "$SCRATCH/notes.tar.xz"
    run_avm image create x --linux debian-13 --cloud-image "$SCRATCH/notes.tar.xz"
    assert_status 1 || return 1
    assert_err_contains "it is neither an xz-compressed tar archive nor a raw disk with a partition table" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}
