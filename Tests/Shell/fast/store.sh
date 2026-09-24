#!/bin/bash
#
# Tests/Shell/fast/store.sh - images and boxes as records on disk, driven through the CLI
# against stand-in images (fake_image): listing, cloning into boxes, network rules, deleting.
# No virtual machine is started.

test_images_list_and_delete() {
    fake_image dev
    fake_image broken failed
    run_avm image list --json
    assert_status 0 || return 1
    assert_json 0.name broken || return 1
    assert_json 1.name dev || return 1
    assert_json 1.state ready || return 1

    run_avm image list
    assert_out_contains "dev  ready" || return 1

    run_avm image delete broken
    assert_status 0 || return 1
    assert_missing "$AGENT_VM_HOME/Images/broken" || return 1
    run_avm image delete broken
    assert_status 1 || return 1
    assert_err_contains "no image broken" || return 1
}

test_a_box_is_a_clone_with_its_own_identity() {
    fake_image dev
    run_avm box create b1 --image dev --allow pack:github --json
    assert_status 0 || return 1
    assert_json image dev || return 1
    assert_json network.mode allowlist || return 1
    assert_json network.allow.0 pack:github || return 1
    local _box="$AGENT_VM_HOME/Boxes/b1"
    assert_eq "$(/bin/cat "$_box/Disk.img")" "disk" "cloned disk" || return 1
    assert_not_contains "$(/bin/cat "$_box/MachineIdentifier")" "id" "machine identifier" || return 1
    assert_eq "$(/usr/bin/stat -f %Lp "$_box/Password")" "600" "password mode" || return 1

    run_avm box list --json
    assert_json 0.running false || return 1

    run_avm box create b1 --image dev
    assert_status 1 || return 1
    assert_err_contains "already exists" || return 1
}

test_boxes_need_a_ready_image() {
    fake_image half provisioning
    run_avm box create b1 --image half
    assert_status 1 || return 1
    assert_err_contains "it is provisioning" || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/b1" || return 1
}

test_network_rules_are_checked_and_changed() {
    fake_image dev
    run_avm box create b1 --image dev --allow "not a host"
    assert_status 1 || return 1
    assert_err_contains "not a usable network rule" || return 1
    run_avm box create b1 --image dev --allow pack:nope
    assert_status 1 || return 1
    assert_err_contains "unknown pack" || return 1

    run_avm box create b1 --image dev
    assert_status 0 || return 1
    assert_out_contains "nothing allowed yet" || return 1

    run_avm box network b1 --allow example.com --allow "*.example.org" --allow api.example.net:8443
    assert_status 0 || return 1
    assert_out_contains "example.com, *.example.org, api.example.net:8443" || return 1
    run_avm box network b1 --disallow example.com
    assert_status 0 || return 1
    assert_not_contains "$OUT" "example.com," || return 1
    run_avm box network b1 --disallow missing.example
    assert_status 64 || return 1

    run_avm box network b1 --net off
    assert_status 0 || return 1
    assert_out_contains "off (every connection refused and logged)" || return 1
    run_avm box network b1 --net open --clear --json
    assert_status 0 || return 1
    assert_json mode open || return 1
    assert_json allow 0 || return 1
}

test_packs_are_listed() {
    run_avm box packs
    assert_status 0 || return 1
    local _pack
    for _pack in anthropic apple-updates github homebrew npm openai pypi swiftpm; do
        assert_out_contains "pack:$_pack" || return 1
    done
}

test_a_stopped_box_refuses_exec_and_stop() {
    fake_image dev
    run_avm box create b1 --image dev
    run_avm exec --box b1 -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "is not running" || return 1
    run_avm box stop b1
    assert_status 1 || return 1
    assert_err_contains "is not running" || return 1
    run_avm box netlog b1
    assert_status 0 || return 1
    assert_out_contains "No connections logged" || return 1
    run_avm box execlog b1
    assert_status 0 || return 1
    assert_out_contains "Nothing run in box b1" || return 1
    run_avm box delete b1
    assert_status 0 || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/b1" || return 1
}

test_names_are_checked() {
    run_avm box create Bad --image dev
    assert_status 64 || return 1
    assert_err_contains "not a usable box name" || return 1
    run_avm box delete Bad
    assert_status 1 || return 1
    assert_err_contains "not a usable box name" || return 1
    run_avm image delete ../etc
    assert_status 1 || return 1
}

# Images from before guest features were recorded (or with an older agent-vm-guest) say what
# they lack and how to add it; updating needs a ready image.
test_images_name_missing_guest_features() {
    fake_image dev
    fake_image broken failed
    run_avm image list
    assert_status 0 || return 1
    assert_out_contains "agent-vm-guest lacks terminal; \`agent-vm image update-guest dev\` adds it" || return 1
    assert_out_contains "Full Disk Access for agent-vm-guest is not checked; \`agent-vm image setup dev\`" || return 1
    run_avm image setup broken
    assert_status 1 || return 1
    assert_err_contains "cannot set up image broken: it is failed" || return 1
    assert_not_contains "$OUT" "update-guest broken" "stdout" || return 1
    run_avm image update-guest broken
    assert_status 1 || return 1
    assert_err_contains "cannot update the guest daemon of image broken: it is failed" || return 1
    run_avm image update-guest nosuch
    assert_status 1 || return 1
    assert_err_contains "no image nosuch" || return 1
}

test_box_execlog_needs_a_box() {
    run_avm box execlog nosuch
    assert_status 1 || return 1
    assert_err_contains "no box nosuch" || return 1
}

test_box_view_needs_a_running_box() {
    fake_image dev
    run_avm box create b1 --image dev
    run_avm box view b1
    assert_status 1 || return 1
    assert_err_contains "box b1 is not running" || return 1
    run_avm box view nosuch
    assert_status 1 || return 1
    assert_err_contains "no box nosuch" || return 1
}
