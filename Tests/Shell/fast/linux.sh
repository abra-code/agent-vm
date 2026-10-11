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
    assert_err_contains "--linux nope: this agent-vm knows debian-13 (debian alone means its newest)" || return 1
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

# A recipe says which guest it is for (one that says nothing is for macOS), and one for the
# other guest is refused before anything is cloned, downloaded or booted.
test_a_recipe_for_the_other_guest_is_refused_before_anything_boots() {
    fake_linux_image deb
    fake_image dev
    local _recipes="$TESTS_DIR/../../Recipes"
    run_avm image create x --from deb --recipe "$_recipes/homebrew/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "Recipes/homebrew/recipe.json: it is for macOS images, and image deb runs Linux" || return 1
    assert_err_contains '(a recipe for Linux images says "guest": "linux", one for both "guest": "any")' || return 1
    run_avm image create x --from dev --recipe "$_recipes/linux-node/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "Recipes/linux-node/recipe.json: it is for Linux images, and image dev runs macOS" || return 1
    # The second of two is found too, and a new Linux image refuses a macOS recipe as well.
    run_avm image create x --from deb --recipe "$_recipes/linux-node/recipe.json" --recipe "$_recipes/node/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "Recipes/node/recipe.json: it is for macOS images, and image deb runs Linux" || return 1
    run_avm image create x --linux debian-13 --recipe "$_recipes/homebrew/recipe.json"
    assert_status 1 || return 1
    assert_err_contains "Recipes/homebrew/recipe.json: it is for macOS images, and image x runs Linux" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
    assert_missing "$AGENT_VM_HOME/Cache" || return 1
    # recipe check says which guest each is for.
    run_avm recipe check "$_recipes/linux-node/recipe.json" "$_recipes/agent-clis/recipe.json" "$_recipes/node/recipe.json"
    assert_status 0 || return 1
    assert_out_contains "linux-node/recipe.json: ok (linux-node: for Linux, 3 steps, 1 update step, 3 checks)" || return 1
    assert_out_contains "agent-clis/recipe.json: ok (agent-clis: for any guest, " || return 1
    assert_out_contains "node/recipe.json: ok (node: for macOS, " || return 1
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
    assert_err_contains "it is neither an xz-compressed tar archive, a qcow2 disk image, nor a raw disk with a partition table" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

# Ubuntu is known and withheld: refused with the reason before anything is made or fetched.
test_linux_ubuntu_is_withheld() {
    local _release
    for _release in ubuntu-26.04 ubuntu; do
        run_avm image create x --linux "$_release"
        assert_status 1 || return 1
        assert_err_contains "--linux $_release: Ubuntu 26.04 is not offered in this release: it packages no kernel with 16 KiB pages" || return 1
        assert_err_contains "this agent-vm builds debian-13" || return 1
    done
    # A file of one's own does not get around it: refused before the file is looked at.
    printf 'not a disk' > "$SCRATCH/own.img"
    run_avm image create x --linux ubuntu --cloud-image "$SCRATCH/own.img"
    assert_status 1 || return 1
    assert_err_contains "--linux ubuntu: Ubuntu 26.04 is not offered in this release" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
    assert_missing "$AGENT_VM_HOME/Cache" || return 1
    # Nor does a rebuild of an image that exists.
    fake_linux_image deb
    run_avm image rebuild deb --linux ubuntu-26.04
    assert_status 1 || return 1
    assert_err_contains "--linux ubuntu-26.04: Ubuntu 26.04 is not offered in this release" || return 1
    assert_missing "$AGENT_VM_HOME/Images/deb.rebuild" || return 1
}

# With the variable for tests of what is not released, Ubuntu is taken by its name and by the
# distribution's alone: the command gets as far as looking at the file.
test_linux_ubuntu_is_a_known_release() {
    export AGENT_VM_WITHHELD_LINUX=1
    local _linux
    _linux="$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest"
    if [ ! -x "$_linux" ]; then
        skip "this build has no linux/agent-vm-guest"
        return 0
    fi
    local _release
    for _release in ubuntu-26.04 ubuntu; do
        run_avm image create x --linux "$_release" --cloud-image "$SCRATCH/none.img"
        assert_status 1 || return 1
        assert_err_contains "--cloud-image $SCRATCH/none.img: no such file" || return 1
    done
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}

# A qcow2 file that needs what agent-vm does not read is refused by its header, with what it
# needs, before an image is created: here a version 2 file that names a backing file.
test_cloud_image_of_the_wrong_kind_is_refused() {
    local _linux
    _linux="$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest"
    if [ ! -x "$_linux" ]; then
        skip "this build has no linux/agent-vm-guest"
        return 0
    fi
    printf 'QFI\373\0\0\0\2\0\0\0\0\0\0\1\0' > "$SCRATCH/backed.img"
    /usr/bin/head -c 200 /dev/zero >> "$SCRATCH/backed.img"
    export AGENT_VM_WITHHELD_LINUX=1
    run_avm image create x --linux ubuntu-26.04 --cloud-image "$SCRATCH/backed.img"
    assert_status 1 || return 1
    assert_err_contains "backed.img is not a disk image agent-vm can read: it needs a backing file" || return 1
    assert_missing "$AGENT_VM_HOME/Images/x" || return 1
}
