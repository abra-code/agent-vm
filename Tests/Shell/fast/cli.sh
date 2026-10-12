#!/bin/bash
#
# Tests/Shell/fast/cli.sh - the command line itself: version, help, usage errors, doctor, and
# exec's own failures. No virtual machine.

test_version() {
    run_avm --version
    assert_status 0 || return 1
    assert_contains "$OUT" "." "version" || return 1
}

test_help_lists_the_commands() {
    run_avm --help
    assert_status 0 || return 1
    local _command
    for _command in exec connect box image job session doctor; do
        assert_out_contains "$_command" || return 1
    done
}

test_unknown_command_is_a_usage_error() {
    run_avm bogus
    assert_status 64 || return 1
    assert_err_contains "Unexpected argument" || return 1
}

test_doctor_reports_every_check_as_json() {
    run_avm doctor --json
    assert_status 0 || return 1
    assert_json checks 9 || return 1
    assert_json checks.0.name macOS || return 1
    # The binary under test is the signed one: it must carry the entitlement.
    assert_json checks.2.name entitlement || return 1
    assert_json checks.2.status ok || return 1
    assert_json checks.5.name "store folder" || return 1
    # The last check is about Linux guests, and never a failure.
    assert_json checks.8.name "linux guest daemon" || return 1

    # A store folder others may list is reported, and made private by the first write.
    /bin/mkdir -p "$AGENT_VM_HOME"
    /bin/chmod 755 "$AGENT_VM_HOME"
    run_avm doctor --json
    assert_json checks.5.status warning || return 1
    make_project "$SCRATCH/project"
    run_avm session start --project "$SCRATCH/project" --json
    assert_status 0 || return 1
    run_avm doctor --json
    assert_json checks.5.status ok || return 1
}

test_an_ad_hoc_build_keeps_passwords_in_files() {
    # The binary under test is ad hoc signed: the Keychain would ask about its items after
    # every rebuild. A build signed with a Developer ID may use the Keychain.
    local _signature
    _signature="$(/usr/bin/codesign -d -v "$AGENT_VM" 2>&1)"
    case "$_signature" in
        *"flags="*adhoc*) ;;
        *) skip "the agent-vm under test is not ad hoc signed"; return 0 ;;
    esac
    run_avm store secure-passwords
    assert_status 1 || return 1
    assert_err_contains "ad hoc build" || return 1
    run_avm doctor --json
    assert_json checks.6.name "account passwords" || return 1
    assert_json checks.6.status ok || return 1
}

test_exec_needs_a_program() {
    run_avm exec --box anything
    assert_status 64 || return 1
    assert_err_contains "give the program to run after --" || return 1
}

test_exec_failures_of_agent_vm_itself_exit_125() {
    run_avm exec --box nosuchbox -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "no box nosuchbox" || return 1
}

test_exec_rejects_malformed_environment() {
    # A value given without its name is not repeated in the error.
    run_avm exec --box anything --env =sk-value-123 -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "NAME=VALUE or the NAME of a variable" || return 1
    assert_not_contains "$ERR" "sk-value-123" "the error" || return 1
    run_avm exec --box anything --env sk-value-123 -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "is not a name" || return 1
    assert_not_contains "$ERR" "sk-value-123" "the error" || return 1
}

# Checked before the box: a missing variable is a usage error, and no value is printed.
test_exec_passes_on_only_variables_that_are_set() {
    run_cmd /usr/bin/env -u AVM_TEST_UNSET "$AGENT_VM" exec --box nosuchbox --env AVM_TEST_UNSET -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "AVM_TEST_UNSET is not set in agent-vm's environment" || return 1
    # Set, so the next check is the box.
    run_cmd /usr/bin/env AVM_TEST_KEY=sk-test-value "$AGENT_VM" exec --box nosuchbox --env AVM_TEST_KEY -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "no box nosuchbox" || return 1
}

test_exec_checks_environment_files() {
    run_avm exec --box nosuchbox --env-file "$SCRATCH/none.env" -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "cannot read environment file $SCRATCH/none.env" || return 1
    printf 'GOOD=1\nexport SECRET=hunter2\n' > "$SCRATCH/bad.env"
    run_avm exec --box nosuchbox --env-file "$SCRATCH/bad.env" -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "bad.env, line 2" || return 1
    assert_not_contains "$ERR" "hunter2" "stderr" || return 1
    printf '# keys\nGOOD=1\n' > "$SCRATCH/good.env"
    run_avm exec --box nosuchbox --env-file "$SCRATCH/good.env" -- /usr/bin/true
    assert_status 125 || return 1
}

# A terminal session needs a terminal here; checked before any box.
test_terminal_sessions_need_a_terminal() {
    run_avm exec -t --box nosuchbox -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "--tty needs a terminal on stdin" || return 1
    run_avm box shell nosuchbox
    assert_status 64 || return 1
    assert_err_contains "box shell needs a terminal on stdin" || return 1
}

test_box_view_types_one_thing() {
    run_avm box view nosuchbox --type-password --type x
    assert_status 64 || return 1
    assert_err_contains "--type-password and --type do not go together" || return 1
}

# agent-vm version names the guest daemon next to it, with the digest images record.
# The package document's version is the tool's, and its component's identifier ends with it:
# one identifier for every version makes Installer empty the folder of the version before.
test_package_project_names_this_version() {
    run_avm --version
    local _version="$OUT"
    local _document="$REPO_ROOT/Packaging/agent-vm.pkgbld"
    local _packaged
    _packaged="$(/usr/bin/jq -r '.PROJECT.VERSION' "$_document")"
    assert_eq "$_packaged" "$_version" "the package document's version" || return 1
    local _identifier
    _identifier="$(/usr/bin/jq -r '.COMPONENTS[0].IDENTIFIER' "$_document")"
    assert_eq "$_identifier" "com.abracode.pkg.agent-vm.$_version" "the component's identifier" || return 1
}

test_version_names_the_guest_daemon() {
    run_avm --version
    local _version="$OUT"
    run_avm version --json
    assert_status 0 || return 1
    assert_json version "$_version" || return 1
    assert_json controlProtocol 1 || return 1
    assert_json guestProtocol 1 || return 1
    assert_json guestDaemon.version "$_version" || return 1
    assert_json guestDaemon.protocol 1 || return 1
    assert_json guestDaemon.features.0 terminal || return 1
    local _guest
    _guest="$(/usr/bin/dirname "$AGENT_VM")/agent-vm-guest"
    local _digest
    _digest="$(/usr/bin/shasum -a 256 "$_guest" | /usr/bin/awk '{ print $1 }')"
    assert_json guestDaemon.digest "$_digest" || return 1
    # The designated requirement, as codesign states it.
    local _requirement
    _requirement="$(/usr/bin/codesign -d -r- "$_guest" 2>/dev/null | /usr/bin/sed -n 's/^[# ]*designated => //p')"
    [ -n "$_requirement" ] || { fail "codesign -d -r- named no designated requirement for $_guest"; return 1; }
    assert_json guestDaemon.requirement "$_requirement" || return 1
    run_avm version
    assert_status 0 || return 1
    assert_out_contains "agent-vm $_version (control protocol 1, guest protocol 1)" || return 1
    assert_out_contains "sha256 $_digest" || return 1
    assert_out_contains "signature: $_requirement" || return 1
}

# The daemon for Linux guests is found in the linux folder beside agent-vm and named by its digest; it is not run.
# A build without it says so, and nothing else changes.
test_version_names_the_linux_guest_daemon() {
    local _linux
    _linux="$(/usr/bin/dirname "$AGENT_VM")/linux/agent-vm-guest"
    run_avm version --json
    assert_status 0 || return 1
    assert_json linuxGuestDaemon.path "$_linux" || return 1
    if [ ! -x "$_linux" ]; then
        assert_json linuxGuestDaemon.error "no linux/agent-vm-guest executable at $_linux" || return 1
        run_avm version
        assert_status 0 || return 1
        assert_out_contains "linux/agent-vm-guest: no linux/agent-vm-guest executable at $_linux" || return 1
        run_avm doctor --json
        assert_json checks.8.status info || return 1
        skip "this build has no linux/agent-vm-guest (Scripts/build.sh builds it with a swift.org toolchain and the static Linux SDK)"
        return 0
    fi
    local _digest
    _digest="$(/usr/bin/shasum -a 256 "$_linux" | /usr/bin/awk '{ print $1 }')"
    assert_json linuxGuestDaemon.digest "$_digest" || return 1
    local _error
    _error="$(json_value linuxGuestDaemon.error)"
    [ -z "$_error" ] || { fail "the Linux daemon has an error: $_error"; return 1; }
    run_avm version
    assert_status 0 || return 1
    assert_out_contains "linux/agent-vm-guest (for Linux guests)" || return 1
    assert_out_contains "sha256 $_digest" || return 1
    run_avm doctor --json
    assert_json checks.8.name "linux guest daemon" || return 1
    assert_json checks.8.status info || return 1
    assert_contains "$(json_value checks.8.detail)" "$(printf '%s' "$_digest" | /usr/bin/cut -c1-12)" "the doctor line" || return 1
}

# What a new image can be, for a program that offers the choice: the Linux systems --linux takes,
# in agent-vm's order, and each guest's default and smallest sizes. No store and no network.
test_version_lists_the_linux_releases_and_sizes() {
    export AGENT_VM_HOME="$SCRATCH/no-store"
    run_avm version --json
    assert_status 0 || return 1
    assert_json linuxReleases.0.id debian-13 || return 1
    assert_json linuxReleases.0.name "Debian 13" || return 1
    assert_json linuxReleases.0.distribution debian || return 1
    assert_json linuxReleases.0.version 13 || return 1
    local _second
    _second="$(json_value linuxReleases.1.id)"
    [ -z "$_second" ] || { fail "a second release, $_second: add it to this test and to Docs/linux-boxes.md"; return 1; }
    assert_json imageSizes.linux.cpuCount 4 || return 1
    assert_json imageSizes.linux.memoryBytes 4294967296 || return 1
    assert_json imageSizes.linux.diskBytes 34359738368 || return 1
    assert_json imageSizes.linux.minimumDiskBytes 8589934592 || return 1
    assert_json imageSizes.linux.minimumDiskGrowthBytes 1073741824 || return 1
    assert_json imageSizes.macos.cpuCount 4 || return 1
    assert_json imageSizes.macos.memoryBytes 8589934592 || return 1
    assert_json imageSizes.macos.diskBytes 68719476736 || return 1
    assert_json imageSizes.macos.minimumDiskBytes 42949672960 || return 1
    assert_json imageSizes.macos.minimumDiskGrowthBytes 8589934592 || return 1
    run_avm version
    assert_status 0 || return 1
    assert_out_contains "Linux systems for image create --linux: debian-13 (Debian 13)" || return 1
    assert_not_contains "$OUT" "ubuntu" "the systems listed" || return 1
    # A withheld system is listed for a test of what is not released.
    export AGENT_VM_WITHHELD_LINUX=1
    run_avm version --json
    assert_status 0 || return 1
    assert_json linuxReleases.1.id ubuntu-26.04 || return 1
    assert_json linuxReleases.1.name "Ubuntu 26.04" || return 1
    unset AGENT_VM_WITHHELD_LINUX
    assert_missing "$AGENT_VM_HOME" || return 1
}

# Secrets in the Keychain, through the signed binary only: every item is stored, read and
# deleted by the same agent-vm, so macOS never asks. A service of this run's own keeps real
# secrets out of reach; the trap deletes what the test stored, however it ends.
test_secrets_are_stored_listed_used_and_deleted() {
    export AGENT_VM_SECRET_SERVICE="agent-vm-shtest-$$-$RANDOM"
    trap '"$AGENT_VM" secret delete SHTEST_KEY > /dev/null 2>&1' EXIT
    local _value="s3cr3t-$RANDOM-value"
    run_avm_input "$_value
" secret set SHTEST_KEY
    assert_status 0 || return 1
    assert_out_contains "Stored secret SHTEST_KEY" || return 1
    run_avm secret list --json
    assert_status 0 || return 1
    assert_json 0.name SHTEST_KEY || return 1
    assert_json 0.readable true || return 1
    # Replacing a value, and using it: the secret is read before the box is looked up.
    run_avm_input "$_value-2" secret set SHTEST_KEY
    assert_status 0 || return 1
    run_avm exec --box nosuchbox --secret SHTEST_KEY --secret OTHER=SHTEST_KEY -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "no box nosuchbox" || return 1
    assert_not_contains "$OUT$ERR" "$_value" "output" || return 1
    run_avm exec --box nosuchbox --secret SHTEST_MISSING -- /usr/bin/true
    assert_status 125 || return 1
    assert_err_contains "no secret SHTEST_MISSING in the Keychain" || return 1
    run_avm exec --box nosuchbox --secret VAR=sk-not-a-name -- /usr/bin/true
    assert_status 64 || return 1
    assert_not_contains "$ERR" "sk-not-a-name" "stderr" || return 1
    run_avm secret delete not-a-name
    assert_status 64 || return 1
    run_avm_input "" secret set SHTEST_EMPTY
    assert_status 1 || return 1
    assert_err_contains "the value is empty" || return 1
    run_avm secret set not-a-name
    assert_status 64 || return 1
    run_avm secret delete SHTEST_KEY
    assert_status 0 || return 1
    run_avm secret list
    assert_out_contains "No secrets." || return 1
    run_avm secret delete SHTEST_KEY
    assert_status 1 || return 1
    assert_err_contains "no secret SHTEST_KEY" || return 1
}

# image fetch-ipsw against a local file server (AGENT_VM_IPSW_URL): what --check reports, the
# refusals, and a complete download that is not a restore image, which must not stay.
test_fetch_ipsw_checks_and_refuses() {
    local _served="$SCRATCH/served"
    /bin/mkdir -p "$_served"
    /bin/dd if=/dev/zero of="$_served/UniversalMac_99.0_99A1_Restore.ipsw" bs=1024 count=512 2>/dev/null
    local _port=$(( 30000 + $$ % 20000 ))
    /usr/bin/python3 -m http.server --bind 127.0.0.1 --directory "$_served" "$_port" > /dev/null 2>&1 &
    local _server=$!
    local _tries=0
    local _up=1
    while [ "$_tries" -lt 50 ]; do
        # Our file, so another server on the same port is not mistaken for this one.
        /usr/bin/curl -sf -o /dev/null -I "http://127.0.0.1:$_port/UniversalMac_99.0_99A1_Restore.ipsw"
        _up=$?
        [ "$_up" -eq 0 ] && break
        _tries=$(( _tries + 1 ))
        /bin/sleep 0.1
    done
    if [ "$_up" -ne 0 ]; then
        kill "$_server"
        fail "the local file server did not start on port $_port"
        return 1
    fi

    local _url="http://127.0.0.1:$_port/UniversalMac_99.0_99A1_Restore.ipsw"
    local _cached="$AGENT_VM_HOME/Cache/ipsw/UniversalMac_99.0_99A1_Restore.ipsw"
    AGENT_VM_IPSW_URL="$_url" run_avm image fetch-ipsw --check --json
    assert_status 0 || { kill "$_server"; return 1; }
    assert_json state missing || { kill "$_server"; return 1; }
    assert_json totalBytes 524288 || { kill "$_server"; return 1; }
    assert_json path "$_cached" || { kill "$_server"; return 1; }

    # Downloaded in full, but not a restore image: refused and deleted.
    AGENT_VM_IPSW_URL="$_url" run_avm image fetch-ipsw
    assert_status 1 || { kill "$_server"; return 1; }
    assert_err_contains "not a restore image this Mac can use" || { kill "$_server"; return 1; }
    assert_missing "$_cached" || { kill "$_server"; return 1; }
    kill "$_server"

    AGENT_VM_IPSW_URL="http://127.0.0.1:$_port/notes.txt" run_avm image fetch-ipsw --check
    assert_status 1 || return 1
    assert_err_contains "not a restore image (.ipsw) file name" || return 1
    # Nothing listens now.
    AGENT_VM_IPSW_URL="$_url" run_avm image fetch-ipsw --check
    assert_status 1 || return 1
    assert_err_contains "cannot download $_url" || return 1
    # A given address is https, or this Mac: nothing is asked of another host over plain http.
    AGENT_VM_IPSW_URL="http://example.com/UniversalMac_99.0_99A1_Restore.ipsw" run_avm image fetch-ipsw --check
    assert_status 64 || return 1
    assert_err_contains "must be an https address" || return 1
}

test_fetch_ipsw_lists_and_create_finds_by_name() {
    run_avm image fetch-ipsw --list
    assert_status 0 || return 1
    assert_out_contains "No restore image is downloaded" || return 1
    run_avm image fetch-ipsw --list --check
    assert_status 64 || return 1

    # Listed, but Virtualization cannot use it, so it is not the latest.
    local _dir="$AGENT_VM_HOME/Cache/ipsw"
    /bin/mkdir -p "$_dir"
    printf 'not a restore image' > "$_dir/UniversalMac_99.0_99A1_Restore.ipsw"
    run_avm image fetch-ipsw --list --json
    assert_status 0 || return 1
    assert_json 0.name UniversalMac_99.0_99A1_Restore.ipsw || return 1
    assert_json 0.bytes 19 || return 1
    assert_json 0.latest false || return 1
    local _problem="$(json_value 0.problem)"
    [ -n "$_problem" ] || { fail "no problem reported for a file that is not a restore image"; return 1; }

    run_avm image create x --ipsw latest
    assert_status 1 || return 1
    assert_err_contains "no usable restore image is downloaded" || return 1
    run_avm image create x --ipsw nosuch.ipsw
    assert_status 1 || return 1
    assert_err_contains "is neither a file in the current directory nor a restore image downloaded" || return 1
}

# A closed standard error, or standard output, does not crash agent-vm: what cannot be said is
# left unsaid. (Foundation's FileHandle raised an exception there, which ended the program with
# status 134 and a crash report.)
test_closed_standard_streams_do_not_crash() {
    fake_image dev
    run_avm box create d1 --image dev --disposable
    assert_status 0 || return 1
    printf 'stopped\n' > "$AGENT_VM_HOME/Boxes/d1/tombstone"
    # box list collects the stopped box and says so on standard error, which is closed.
    OUT="$("$AGENT_VM" box list --json 2>&-)"
    local _status=$?
    assert_eq "$_status" "0" "box list with standard error closed" || return 1
    assert_eq "$OUT" "[

]" "its answer on standard output" || return 1
    assert_missing "$AGENT_VM_HOME/Boxes/d1" || return 1
    # JSON on a closed standard output: nothing to write to, and no crash.
    "$AGENT_VM" version --json >&- 2>/dev/null
    _status=$?
    assert_eq "$_status" "0" "version --json with standard output closed" || return 1
    # An error of agent-vm's own with both closed still ends with its status.
    "$AGENT_VM" box status nosuch >&- 2>&-
    _status=$?
    assert_eq "$_status" "1" "an error with both closed" || return 1
}

# A closed standard error does not lend its number to a file agent-vm opens: a message meant
# for it must not land in the store. box list takes locks and reads records with it closed, and
# says on it that it deleted a stopped disposable box.
test_a_closed_standard_error_does_not_reach_the_store() {
    fake_image dev
    run_avm box create keep --image dev
    run_avm box create d1 --image dev --disposable
    printf 'stopped\n' > "$AGENT_VM_HOME/Boxes/d1/tombstone"
    "$AGENT_VM" box list 2>&- > /dev/null
    local _status=$?
    assert_eq "$_status" "0" "box list with standard error closed" || return 1
    local _found
    _found="$(/usr/bin/grep -rl "deleted disposable box" "$AGENT_VM_HOME" 2>/dev/null)"
    [ -z "$_found" ] || { fail "the note for standard error is in the store: $_found"; return 1; }
}
