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
    assert_out_contains "agent-vm-guest lacks terminal, prompt-notices, wallpaper, time-sync, user-session, terminal-pixels; \`agent-vm image update dev --guest\` adds it" || return 1
    assert_out_contains "Full Disk Access for agent-vm-guest is not checked; \`agent-vm image setup dev\`" || return 1
    run_avm image setup broken
    assert_status 1 || return 1
    assert_err_contains "cannot set up image broken: it is failed" || return 1
    assert_not_contains "$OUT" "image update broken" "stdout" || return 1
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
    # Deprecated: it still works, and says what to use.
    assert_err_contains "image update-guest is deprecated" || return 1
    run_avm image --help
    assert_not_contains "$OUT" "update-guest" "image --help" || return 1
    run_avm image update-guest
    assert_status 64 || return 1
    assert_err_contains "Missing expected argument '<image> ...'" || return 1
}

# image update checks every name and every option before anything boots.
test_update_checks_every_name_first() {
    fake_image dev
    fake_image broken failed
    run_avm image update dev nosuch
    assert_status 1 || return 1
    assert_err_contains "no image nosuch" || return 1
    assert_not_contains "$OUT" "Booting" "stdout" || return 1
    run_avm image update dev broken --tools
    assert_status 1 || return 1
    assert_err_contains "cannot update image broken: it is failed" || return 1
    run_avm image update
    assert_status 64 || return 1
    assert_err_contains "Missing expected argument '<image> ...'" || return 1
    run_avm image update dev --macos --set channel=beta
    assert_status 64 || return 1
    assert_err_contains "--set changes a recipe's parameter for the tools update" || return 1
    run_avm image update dev --guest --set channel=beta
    assert_status 64 || return 1
    assert_err_contains "leave out --macos and --guest" || return 1
    run_avm image update dev --tools --set channel
    assert_status 64 || return 1
    assert_err_contains "channel: give name=value" || return 1
    # A --set that the last image's recipes do not take, too.
    fake_image other
    run_avm image update dev other --tools --set channel=beta
    assert_status 1 || return 1
    assert_err_contains "--set channel: dev keeps no recipe with update steps" || return 1
    assert_not_contains "$OUT" "Booting" "stdout" || return 1
    assert_missing "$AGENT_VM_HOME/Images/dev/Update" || return 1
}

# --if-older-than skips an image that was checked lately, without booting it.
test_update_skips_an_image_checked_lately() {
    fake_image dev
    local _now
    _now="$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
    /usr/bin/sed -i '' -e "s/\"macOSBuild\" : \"26A428\"/\"macOSBuild\" : \"26A428\", \"toolsCheckedAt\" : \"$_now\"/" "$AGENT_VM_HOME/Images/dev/image.json"
    run_avm image update dev --tools --if-older-than 24
    assert_status 0 || return 1
    assert_out_contains "Image dev: its tools checked less than 24 hours ago: not checked again" || return 1
    assert_not_contains "$OUT" "Booting" "stdout" || return 1
    run_avm image update dev --tools --if-older-than 24 --json
    assert_status 0 || return 1
    assert_json name "dev" || return 1
    # The tools were checked, macOS never was: asking for both is not skipped (and this fake
    # image then fails to boot).
    run_avm image update dev --macos --tools --if-older-than 24
    assert_not_contains "$OUT" "not checked again" "stdout" || return 1
    [ "$STATUS" -ne 0 ] || { fail "a fake image booted"; return 1; }
    run_avm image update dev --tools --if-older-than nan
    assert_status 64 || return 1
    assert_err_contains "--if-older-than takes a number of hours" || return 1
    run_avm image update dev --tools --if-older-than inf
    assert_status 64 || return 1
    # A number of hours too large for an integer is still only a number.
    run_avm image update dev --tools --if-older-than 1e30
    assert_status 0 || return 1
    assert_out_contains "less than 1e+30 hours ago" || return 1
}

# A box says why it needs recreating: its image was updated (its revision moved on).
test_a_box_of_an_updated_image_needs_recreating() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    run_avm box list
    assert_not_contains "$OUT" "needs recreate" "box list" || return 1
    /usr/bin/sed -i '' -e 's/"macOSBuild" : "26A428"/"macOSBuild" : "26A434", "revision" : 1, "updatedAt" : "2026-10-01T07:00:00Z"/' "$AGENT_VM_HOME/Images/dev/image.json"
    run_avm box list
    assert_out_contains "needs recreate: image dev was updated since this box was made (macOS 26A434 now)" || return 1
    run_avm box list --json
    assert_contains "$OUT" '"reason" : "image-updated"' "box list --json" || return 1
    run_avm image list
    assert_out_contains "updated 2026-10-01" || return 1
    run_avm status
    assert_out_contains "needs recreate" || return 1
    run_avm box recreate b1
    assert_status 0 || return 1
    run_avm box list
    assert_not_contains "$OUT" "needs recreate" "box list after recreate" || return 1
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
    assert_json passwordStorage file || return 1
    assert_out_contains '"unsharedBytes"' || return 1
    run_avm box info b1
    assert_status 0 || return 1
    assert_out_contains "not shared with its image or other boxes (what box delete frees)" || return 1
    run_avm box info b1 --json
    assert_status 0 || return 1
    assert_json box.name b1 || return 1
    assert_json passwordStorage file || return 1
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

# status and image list name an image behind the newest macOS Apple was last asked about, from
# the answer kept in the store: no network, nothing booted.
test_status_names_a_macos_update_from_the_kept_answer() {
    fake_image dev
    fake_image broken failed
    run_avm status
    assert_status 0 || return 1
    assert_not_contains "$OUT" "Newest macOS" "status before Apple was asked" || return 1
    /bin/mkdir -p "$AGENT_VM_HOME/Cache"
    printf '{"version":"27.0.1","build":"26A434","checkedAt":"2026-10-01T08:00:00Z"}' > "$AGENT_VM_HOME/Cache/newest-macos.json"
    run_avm status
    assert_status 0 || return 1
    assert_out_contains "Full Disk Access  macOS 27.0.1 available" || return 1
    assert_out_contains "Newest macOS: 27.0.1 (26A434), asked " || return 1
    # Only the ready image is named in the command.
    assert_out_contains "agent-vm image update dev --macos" || return 1
    run_avm status --json
    assert_json newestMacOS.build 26A434 || return 1
    assert_json images.1.macOSUpdate.version 27.0.1 || return 1
    assert_not_contains "$OUT" "newestMacOSError" "status --json" || return 1
    run_avm image list
    assert_out_contains "macOS 27.0.1 (26A434) is available; \`agent-vm image update dev --macos\` installs it" || return 1
    run_avm image info dev --json
    assert_json macOSUpdate.build 26A434 || return 1
    # The image asked Apple itself later and was offered nothing: no hint.
    /usr/bin/sed -i '' -e 's/"macOSBuild" : "26A428"/"macOSBuild" : "26A428", "macOSCheckedAt" : "2026-10-01T09:00:00Z"/' "$AGENT_VM_HOME/Images/dev/image.json"
    run_avm status
    assert_not_contains "$OUT" "available" "status after the image's own check" || return 1
    assert_not_contains "$OUT" "image update" "status after the image's own check" || return 1
    assert_out_contains "Newest macOS: 27.0.1 (26A434)" || return 1
    run_avm image list --json
    assert_not_contains "$OUT" "macOSUpdate" "image list --json" || return 1
}

# image rebuild refuses what it can before anything is built.
test_rebuild_checks_before_building() {
    fake_image dev
    run_avm image rebuild nosuch
    assert_status 1 || return 1
    assert_err_contains "nosuch" || return 1
    run_avm image rebuild nosuch --ipsw nosuch.ipsw
    assert_status 1 || return 1
    assert_not_contains "$ERR" "restore image" "a missing image named before a missing restore image" || return 1
    run_avm image rebuild dev
    assert_status 1 || return 1
    assert_err_contains "dev was installed from a restore image: give --ipsw" || return 1
    run_avm image rebuild dev --ipsw a.ipsw --from other
    assert_status 64 || return 1
    assert_err_contains "give either --ipsw (install macOS) or --from" || return 1
    run_avm image rebuild dev --from dev
    assert_status 1 || return 1
    assert_err_contains "cannot be rebuilt from itself" || return 1
    fake_image other
    run_avm image rebuild dev --from other
    assert_status 1 || return 1
    assert_err_contains "dev keeps no recipe that other lacks" || return 1
    run_avm image rebuild dev --from other --set size
    assert_status 64 || return 1
    assert_missing "$AGENT_VM_HOME/Images/dev.rebuild" || return 1
    # A job may run it.
    run_avm job start -- image rebuild
    assert_status 64 || return 1
    assert_err_contains "the job's command" || return 1
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

test_a_record_cannot_act_on_the_terminal() {
    fake_image dev
    # What a guest could have answered to an earlier agent-vm, which recorded it as it came.
    local _record="$AGENT_VM_HOME/Images/dev/image.json"
    local _changed
    _changed="$(/usr/bin/jq '.macOSBuild = "26A428\u001b[2J\rspoofed" | .guestVersion = "0.1\u001b]0;title\u0007"' "$_record")"
    [ -n "$_changed" ] || { fail "jq could not change $_record"; return 1; }
    printf '%s\n' "$_changed" > "$_record"

    run_avm image list
    assert_status 0 || return 1
    assert_printable "$OUT" "image list" || return 1
    assert_out_contains "26A428?[2J?spoofed" || return 1
    run_avm status
    assert_status 0 || return 1
    assert_printable "$OUT" "status" || return 1
    run_avm image info dev
    assert_printable "$OUT$ERR" "image info" || return 1
}

# The log's two files are one list, and an open connection shows the bytes last noted.
test_netlog_reads_allowed_and_refused_files() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    local _box="$AGENT_VM_HOME/Boxes/b1"
    printf '%s\n' \
        '{"time":"2026-10-01T10:00:01Z","timeMilliseconds":500,"method":"CONNECT","host":"refused.example","port":443,"decision":"denied","reason":"not in the allowlist"}' \
        > "$_box/network.jsonl"
    printf '%s\n' \
        '{"time":"2026-10-01T10:00:01Z","timeMilliseconds":100,"method":"CONNECT","host":"ended.example","port":443,"decision":"allowed","rule":"public","id":"a","open":true}' \
        '{"time":"2026-10-01T10:00:02Z","timeMilliseconds":0,"method":"CONNECT","host":"running.example","port":443,"decision":"allowed","rule":"public","id":"b","open":true}' \
        '{"time":"2026-10-01T10:00:02Z","timeMilliseconds":0,"method":"CONNECT","host":"running.example","port":443,"decision":"allowed","rule":"public","id":"b","open":true,"partial":true,"bytesUp":700,"bytesDown":90}' \
        '{"time":"2026-10-01T10:00:01Z","timeMilliseconds":100,"method":"CONNECT","host":"ended.example","port":443,"decision":"allowed","rule":"public","id":"a","bytesUp":5,"bytesDown":6}' \
        > "$_box/network-allowed.jsonl"

    run_avm box netlog b1 --json
    assert_status 0 || return 1
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/jq -r '[.[].host] | join(" ")')" "ended.example refused.example running.example" "the order" || return 1
    # The box is stopped: the connection last seen open ended unlogged, and keeps its bytes.
    run_avm box netlog b1
    assert_status 0 || return 1
    assert_out_contains "ended.example:443  [public]  5 up, 6 down" || return 1
    assert_out_contains "running.example:443  [public]  end not logged (the box stopped); 700 up, 90 down before that" || return 1
    run_avm box netlog b1 --denied
    assert_status 0 || return 1
    assert_out_contains "refused.example" || return 1
    assert_not_contains "$OUT" "ended.example" "netlog --denied" || return 1
}

test_json_output_keeps_what_was_logged() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    # A host name with characters the text form replaces (a C1 control, a line separator).
    printf '%s\n' '{"time":"2026-10-01T10:00:00Z","method":"CONNECT","host":"a\u0085b c.example","port":443,"decision":"denied","reason":"no rule"}' \
        > "$AGENT_VM_HOME/Boxes/b1/network.jsonl"

    run_avm box netlog b1
    assert_status 0 || return 1
    assert_out_contains "a?b?c.example" || return 1

    # Both JSON forms give the name as it was logged.
    run_avm box netlog b1 --json
    assert_status 0 || return 1
    local _listed
    _listed="$(printf '%s' "$OUT" | /usr/bin/jq -c '.[0].host')"
    run_avm box netlog b1 --follow --json
    assert_status 0 || return 1
    local _followed
    _followed="$(printf '%s' "$OUT" | /usr/bin/jq -c '.host')"
    assert_eq "$_followed" "$_listed" "the host in netlog --follow --json" || return 1
    assert_not_contains "$_followed" "?" "the host in netlog --follow --json" || return 1
}
