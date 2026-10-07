#!/bin/bash
#
# Tests/Shell/extended/linux-images.sh - image create --linux: a Debian image built from the
# distribution's cloud image (about a minute after a 0.2 GB download, which is kept in the
# store's Cache/linux), the reuse of the downloaded file, and a cancel. Needs the internet, and
# the Linux guest daemon beside agent-vm (Scripts/build.sh builds it when it can): without the
# daemon every test here is skipped. No signing identity is needed.

# require_linux_daemon: returns 1 (and skips) when this build cannot make Linux images.
require_linux_daemon() {
    local _linux
    _linux="$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest"
    if [ ! -x "$_linux" ]; then
        skip "this build has no linux/agent-vm-guest (Scripts/build.sh builds it with a swift.org toolchain and the static Linux SDK)"
        return 1
    fi
    return 0
}

# json_of <file> <jq filter>: a value from a JSON file.
json_of() {
    /usr/bin/jq -r "$2" "$1"
}

test_linux_image_from_the_cloud_image() {
    require_linux_daemon || return 0
    local _image="shtest-linux-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    run_avm image create "$_image" --linux debian-13 --json
    assert_status 0 || return 1
    assert_err_events || return 1
    local _step
    for _step in base-check unpack first-boot guest-daemon linux-setup seal shutdown; do
        assert_err_contains "\"step\":\"$_step\"" || return 1
    done
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(json_of "$SCRATCH/record.json" .state)" "ready" "the image's state" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .guest)" "linux" "the image's guest" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .formatVersion)" "3" "the record's format" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .linux.distribution)" "debian" "the distribution" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .linux.version)" "13" "the version" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .linux.architecture)" "arm64" "the architecture" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" '.guestFeatures | join(" ")')" "terminal time-sync terminal-pixels" "the daemon's features" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .base.release)" "debian-13" "the base's release" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" '.base.sha512 | test("^[0-9a-f]{128}$")')" "true" "the base's SHA-512" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" '.commandLineTools | startswith("build-essential ")')" "true" "the compiler's record" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" 'has("macOSVersion") or has("passwordID") or has("fullDiskAccess")')" "false" "a Mac's keys" || return 1
    assert_eq "$(json_of "$SCRATCH/record.json" .guestVersion)" "$("$AGENT_VM" --version)" "the daemon's version" || return 1

    run_avm image list
    assert_out_contains "$_image  ready         Debian GNU/Linux 13 (trixie)  4 CPUs  4 GB" || return 1
    assert_not_contains "$OUT" "needs" "image list" || return 1
    # What the folder holds: a Linux machine's files, the console's output, and no seed disk.
    local _folder
    _folder="$("$AGENT_VM" image info "$_image" --json | /usr/bin/jq -r .path)"
    [ -d "$_folder" ] || { fail "image info names no folder: [$_folder]"; return 1; }
    local _file
    for _file in Disk.img EFIVariableStore MachineIdentifier console.log; do
        assert_exists "$_folder/$_file" || return 1
    done
    for _file in Seed.iso AuxiliaryStorage HardwareModel Password known_hosts; do
        assert_missing "$_folder/$_file" || return 1
    done
    # A 32 GB disk that takes what the system takes.
    local _blocks
    _blocks="$(/usr/bin/stat -f %b "$_folder/Disk.img")"
    [ "$_blocks" -lt 8388608 ] || { fail "the disk takes $((_blocks / 2048)) MB on the Mac"; return 1; }
    assert_eq "$(/usr/bin/stat -f %z "$_folder/Disk.img")" "34359738368" "the disk's size" || return 1
    local _console
    _console="$(/usr/bin/stat -f %z "$_folder/console.log")"
    [ "$_console" -lt 2097152 ] || { fail "console.log is $_console bytes"; return 1; }
    # A box can be made from it (and not started, yet).
    local _box="shtest-linuxbox-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$_image"
    assert_status 0 || return 1
    run_avm box list
    assert_out_contains "$_box  stopped   image $_image (Debian 13)" || return 1
    run_avm box delete "$_box"
    assert_status 0 || return 1
    run_avm image delete "$_image"
    assert_status 0 || return 1
}

# The second image is made from the file the first one downloaded: the list is asked for, the
# file is checked again, nothing is fetched. Without the compiler, which is most of the time.
test_linux_create_reuses_the_cache() {
    require_linux_daemon || return 0
    local _first="shtest-linux-a-$$"
    local _second="shtest-linux-b-$$"
    cleanup_on_exit image "$_first"
    cleanup_on_exit image "$_second"
    run_avm image create "$_first" --linux debian --no-command-line-tools --json
    assert_status 0 || return 1
    run_avm image create "$_second" --linux debian --no-command-line-tools --json
    assert_status 0 || return 1
    assert_err_events || return 1
    assert_err_contains '"step":"base-check"' || return 1
    assert_not_contains "$ERR" '"step":"download"' "the second build's events" || return 1
    assert_err_contains "is the one the list names" || return 1
    printf '%s' "$OUT" > "$SCRATCH/record.json"
    assert_eq "$(json_of "$SCRATCH/record.json" 'has("commandLineTools")')" "false" "the compiler's record" || return 1
    run_avm image delete "$_first"
    assert_status 0 || return 1
    run_avm image delete "$_second"
    assert_status 0 || return 1
}

# SIGINT while the packages are installed: the guest is shut down, the image is marked failed
# (canceled), and no virtual machine is left.
test_linux_create_cancel() {
    require_linux_daemon || return 0
    local _image="shtest-linux-cancel-$$"
    "$AGENT_VM" image delete "$_image" > /dev/null 2>&1
    cleanup_on_exit image "$_image"
    "$AGENT_VM" image create "$_image" --linux debian-13 --json > "$SCRATCH/create.out" 2> "$SCRATCH/create.err" &
    local _pid=$!
    wait_for_text "$SCRATCH/create.err" '"step":"linux-setup"' 300
    local _reached=$?
    kill -INT "$_pid"
    local _began
    _began="$(/bin/date +%s)"
    wait "$_pid"
    STATUS=$?
    local _took=$(( $(/bin/date +%s) - _began ))
    ERR="$(/bin/cat "$SCRATCH/create.err")"
    printf '%s\n[status %s after %s s]\n' "$ERR" "$STATUS" "$_took"
    [ "$_reached" -eq 0 ] || { fail "the setup did not start within 300 s"; return 1; }
    assert_status 130 || return 1
    assert_err_events || return 1
    assert_err_contains '"message":"Canceled; shutting down","step":"shutdown"' || return 1
    assert_err_contains "is marked failed (canceled): canceled by SIGINT" || return 1
    assert_not_contains "$ERR" "did not shut down" "stderr" || return 1
    [ "$_took" -lt 60 ] || { fail "the cancel took $_took s"; return 1; }
    assert_eq "$(image_state "$_image")" "failed" "the image's state" || return 1
    assert_eq "$(image_value "$_image" failure)" "canceled" "the image's failure" || return 1
    [ ! -s "$SCRATCH/create.out" ] || { fail "stdout is not empty"; return 1; }
    run_avm image delete "$_image"
    assert_status 0 || return 1
}
