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
    run_avm box network b1 --allow public:0
    assert_status 1 || return 1
    assert_err_contains "public or public:port" || return 1
    run_avm box network b1 --allow public --allow public:8443
    assert_status 0 || return 1
    assert_out_contains "api.example.net:8443, public, public:8443" || return 1
    run_avm box network b1 --disallow public --disallow public:8443
    assert_status 0 || return 1

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
    for _pack in anthropic anthropic-connectors apple-updates github homebrew npm openai pypi swiftpm; do
        assert_out_contains "pack:$_pack" || return 1
    done
    # For programs: name and hosts, sorted by name, the names without "pack:", and where each came from.
    run_avm box packs --json
    assert_status 0 || return 1
    assert_json 0.name anthropic || return 1
    assert_json 3.name github || return 1
    assert_json 3.hosts.0 github.com || return 1
    assert_json 3.source built-in || return 1
    assert_json 8.name swiftpm || return 1

    # A user pack replaces the built-in one of its name; a broken one is listed with why.
    /bin/mkdir -p "$AGENT_VM_HOME/Packs"
    printf '%s\n' '{"description": "Our mirror", "hosts": ["npm.example.com"]}' > "$AGENT_VM_HOME/Packs/npm.json"
    printf '%s\n' '{"hosts": ["public"]}' > "$AGENT_VM_HOME/Packs/wide.json"
    run_avm box packs --json
    assert_status 0 || return 1
    assert_json 5.name npm || return 1
    assert_json 5.source user || return 1
    assert_json 5.replacesBuiltIn true || return 1
    assert_json 5.hosts.0 npm.example.com || return 1
    assert_json 9.name wide || return 1
    local _problem="$(json_value 9.problem)"
    assert_contains "$_problem" "public is not a host name" "the broken pack's problem" || return 1
    run_avm box packs
    assert_out_contains "pack:npm  (yours, $AGENT_VM_HOME/Packs/npm.json, replaces the built-in one)" || return 1
}

test_a_stopped_box_refuses_exec_send_and_stop() {
    fake_image dev
    run_avm box create b1 --image dev
    run_avm exec --box b1 -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "is not running" || return 1
    run_avm box stop b1
    assert_status 1 || return 1
    assert_err_contains "is not running" || return 1
    : > "$SCRATCH/file.txt"
    run_avm box send b1 "$SCRATCH/file.txt"
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
    assert_out_contains "agent-vm-guest lacks terminal, prompt-notices, wallpaper, time-sync, user-session, terminal-pixels; \`agent-vm image update-guest dev\` adds it" || return 1
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

# Several images: every name is checked before the first boot, so a bad name anywhere in the
# list refuses the whole run (the fake image dev would fail to boot and say so).
test_update_guest_checks_every_name_first() {
    fake_image dev
    fake_image broken failed
    run_avm image update-guest dev nosuch
    assert_status 1 || return 1
    assert_err_contains "no image nosuch" || return 1
    assert_not_contains "$OUT" "Booting" "stdout" || return 1
    run_avm image update-guest dev dev broken
    assert_status 1 || return 1
    assert_err_contains "cannot update the guest daemon of image broken: it is failed" || return 1
    assert_not_contains "$OUT" "Booting" "stdout" || return 1
    run_avm image update-guest
    assert_status 64 || return 1
    assert_err_contains "Missing expected argument '<image> ...'" || return 1
}

# The lists name each folder and measure nothing; image info and box info add the space it takes,
# in text and in JSON (diskUsage). A list of every image must stay quick, and measuring is not.
test_lists_show_folders_and_info_shows_space() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    run_avm image list
    assert_status 0 || return 1
    assert_out_contains "/Images/dev" || return 1
    assert_not_contains "$OUT" "not shared" "image list" || return 1
    run_avm box list
    assert_status 0 || return 1
    assert_out_contains "/Boxes/b1" || return 1
    assert_not_contains "$OUT" "not shared" "box list" || return 1
    run_avm image list --json
    assert_status 0 || return 1
    assert_out_contains '"macOSBuild"' || return 1
    assert_not_contains "$OUT" '"diskUsage"' "image list --json" || return 1
    run_avm box list --json
    assert_status 0 || return 1
    assert_out_contains 'Boxes\/b1"' || return 1
    assert_not_contains "$OUT" '"diskUsage"' "box list --json" || return 1

    run_avm image info dev
    assert_status 0 || return 1
    assert_out_contains "/Images/dev" || return 1
    assert_out_contains "not shared with other images or boxes (what image delete frees)" || return 1
    run_avm image info dev --json
    assert_status 0 || return 1
    assert_json name dev || return 1
    assert_out_contains '"unsharedBytes"' || return 1
    run_avm box info b1
    assert_status 0 || return 1
    assert_out_contains "not shared with its image or other boxes (what box delete frees)" || return 1
    run_avm box info b1 --json
    assert_status 0 || return 1
    assert_json box.name b1 || return 1
    assert_json state stopped || return 1
    assert_out_contains '"diskUsage"' || return 1
    run_avm image info nosuch
    assert_status 1 || return 1
    assert_err_contains "no image nosuch" || return 1
    run_avm box info nosuch
    assert_status 1 || return 1
    assert_err_contains "no box nosuch" || return 1
}

# status: one line per image and box, and the virtual machine count; it measures nothing and,
# unlike box list, deletes nothing.
test_status_summarizes_without_measuring_or_collecting() {
    fake_image dev
    fake_image broken failed
    run_avm box create b1 --image dev
    run_avm box create d1 --image dev --disposable
    assert_status 0 || return 1
    # A stopped disposable box that box list's gc would delete (its tombstone).
    : > "$AGENT_VM_HOME/Boxes/d1/tombstone"
    run_avm status
    assert_status 0 || return 1
    assert_out_contains "Images:" || return 1
    assert_out_contains "broken" || return 1
    assert_out_contains "failed" || return 1
    assert_out_contains "Boxes:" || return 1
    assert_out_contains "disposable" || return 1
    assert_out_contains "Virtual machines running on this Mac" || return 1
    assert_not_contains "$OUT" "not shared" "status" || return 1
    assert_not_contains "$OUT" "Jobs:" "status" || return 1
    assert_exists "$AGENT_VM_HOME/Boxes/d1" || return 1
    run_avm status --json
    assert_status 0 || return 1
    assert_json images.0.name broken || return 1
    assert_json images.1.name dev || return 1
    assert_json boxes.0.box.name b1 || return 1
    assert_json boxes.0.state stopped || return 1
    assert_json runningVMs.limit 2 || return 1
    assert_not_contains "$OUT" '"diskUsage"' "status --json" || return 1
    # No job ever ran: an empty list, and no Jobs section for a person.
    assert_json jobs 0 || return 1
    assert_missing "$AGENT_VM_HOME/Jobs" || return 1
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

# box status never starts anything: a stopped box reports "stopped" with its record, in the
# same shape as a box list entry.
test_box_status_of_a_stopped_box() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    run_avm box status b1 --json
    assert_status 0 || return 1
    assert_json state stopped || return 1
    assert_json running false || return 1
    assert_json box.name b1 || return 1
    assert_json box.image dev || return 1
    assert_not_contains "$OUT" '"diskUsage"' "box status --json" || return 1
    assert_not_contains "$OUT" '"pid"' "stdout" || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/b1/supervisor.log" || return 1
    run_avm box status b1
    assert_status 0 || return 1
    assert_out_contains "b1  stopped" || return 1
    run_avm box list --json
    assert_json 0.state stopped || return 1
    run_avm box status nosuch
    assert_status 1 || return 1
    assert_err_contains "no box nosuch" || return 1
}

# image list --json carries what each ready image lacks, as the text output names it.
test_image_list_names_what_an_image_needs() {
    fake_image dev
    fake_image broken failed
    run_avm image list --json
    assert_status 0 || return 1
    assert_json 0.name broken || return 1
    assert_json 0.needs 0 || return 1
    assert_json 1.needs 2 || return 1
    assert_json 1.needs.0.kind guest-update || return 1
    assert_json 1.needs.0.missing.0 terminal || return 1
    assert_json 1.needs.1.kind full-disk-access || return 1
    assert_json 1.needs.1.reason not-checked || return 1
    run_avm image list
    assert_out_contains "agent-vm-guest lacks terminal" || return 1
    assert_out_contains "Full Disk Access for agent-vm-guest is not checked" || return 1
}

# A disposable box that stopped (its tombstone) is never started again; gc deletes it, and so do
# box list, box start and doctor on their way.
test_disposable_boxes_are_collected() {
    fake_image dev
    run_avm box create d1 --image dev --disposable --json
    assert_status 0 || return 1
    assert_json disposable true || return 1
    run_avm box status d1 --json
    assert_json disposable true || return 1
    printf 'stopped\n' > "$AGENT_VM_HOME/Boxes/d1/tombstone"
    run_avm box start d1
    assert_status 1 || return 1
    assert_err_contains "box d1 is disposable and has stopped" || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/d1" || return 1

    run_avm box create d2 --image dev --disposable
    run_avm box create kept --image dev
    run_avm box gc --json
    assert_status 0 || return 1
    assert_json deleted 0 || return 1
    printf 'stopped\n' > "$AGENT_VM_HOME/Boxes/d2/tombstone"
    run_avm box list --json
    assert_status 0 || return 1
    assert_err_contains "deleted disposable box d2" || return 1
    assert_json 0.box.name kept || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/d2" || return 1
    run_avm box gc
    assert_out_contains "No disposable boxes to delete." || return 1
}

test_an_owner_must_be_a_running_process() {
    fake_image dev
    run_avm box create b1 --image dev
    run_avm box start b1 --owner-pid 1
    assert_status 64 || return 1
    assert_err_contains "--owner-pid 1: no such process of yours" || return 1
    run_avm box start b1 --owner-pid 999999
    assert_status 64 || return 1
}

test_sync_clock_needs_a_running_box() {
    fake_image dev
    run_avm box create b1 --image dev
    run_avm box sync-clock b1
    assert_status 1 || return 1
    assert_err_contains "box b1 is not running" || return 1
}

# box recreate: a fresh clone with the box's settings; refusals leave the box as it was.
test_recreate_keeps_the_settings() {
    fake_image dev
    fake_image other
    fake_image half provisioning
    run_avm box create b1 --image dev --cpus 2 --memory-gb 3 --allow '*.example.com' --json
    assert_status 0 || return 1
    local _mac
    _mac="$(json_value macAddress)"
    local _box="$AGENT_VM_HOME/Boxes/b1"
    printf 'written in the box' > "$_box/Disk.img"

    run_avm box recreate b1 --image half
    assert_status 1 || return 1
    assert_eq "$(/bin/cat "$_box/Disk.img")" "written in the box" "the disk after a refused recreate" || return 1
    run_avm box recreate b1 --image nosuch
    assert_status 1 || return 1
    assert_err_contains "no image nosuch" || return 1

    run_avm box recreate b1 --json
    assert_status 0 || return 1
    assert_json image dev || return 1
    assert_json cpuCount 2 || return 1
    assert_json memoryBytes 3221225472 || return 1
    assert_json network.allow.0 '*.example.com' || return 1
    [ "$(json_value macAddress)" != "$_mac" ] || { fail "the recreated box kept its MAC address"; return 1; }
    assert_eq "$(/bin/cat "$_box/Disk.img")" "disk" "the disk after recreate" || return 1

    run_avm box recreate b1 --image other
    assert_status 0 || return 1
    assert_out_contains "Recreated box b1 from image other" || return 1
    run_avm box recreate nosuch
    assert_status 1 || return 1
    assert_err_contains "no box nosuch" || return 1
}

# edit_json <file> <jq filter>: rewrites a JSON file through jq.
edit_json() {
    /usr/bin/jq "$2" "$1" > "$1.new"
    local _status=$?
    [ "$_status" -eq 0 ] || { fail "jq $2 on $1 failed"; return 1; }
    /bin/mv "$1.new" "$1"
    _status=$?
    [ "$_status" -eq 0 ] || { fail "cannot replace $1"; return 1; }
}

test_a_box_needs_recreating_after_its_images_guest_changed() {
    fake_image dev
    local _record="$AGENT_VM_HOME/Images/dev/image.json"
    edit_json "$_record" '.guestVersion = "0.4.2" | .guestDigest = "aaaa"' || return 1
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    run_avm box list --json
    assert_json 0.box.guestDigest aaaa || return 1
    assert_json 0.needs 0 || return 1

    # What image update-guest records.
    edit_json "$_record" '.guestVersion = "0.4.3" | .guestDigest = "bbbb"' || return 1
    run_avm box list --json
    assert_json 0.needs.0.kind recreate || return 1
    assert_json 0.needs.0.guestVersion 0.4.3 || return 1
    run_avm box list
    assert_out_contains "needs recreate: image dev has a different agent-vm-guest (0.4.3) from the one this box was made with" || return 1
    run_avm box status b1 --json
    assert_json needs.0.kind recreate || return 1
    run_avm status --json
    assert_json boxes.0.needs.0.kind recreate || return 1
    run_avm status
    assert_out_contains "image dev  needs recreate" || return 1

    # A box made before 0.4.3 recorded no daemon: it still reads, and never needs recreating.
    local _box="$AGENT_VM_HOME/Boxes/b1/box.json"
    edit_json "$_box" 'del(.guestVersion, .guestDigest)' || return 1
    run_avm box list --json
    assert_status 0 || return 1
    assert_not_contains "$ERR" "warning" || return 1
    assert_json 0.box.name b1 || return 1
    assert_json 0.needs 0 || return 1

    run_avm box recreate b1
    assert_status 0 || return 1
    run_avm box list --json
    assert_json 0.box.guestDigest bbbb || return 1
    assert_json 0.needs 0 || return 1
}
