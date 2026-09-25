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
    for _command in exec box image session doctor; do
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
    assert_json checks 6 || return 1
    assert_json checks.0.name macOS || return 1
    # The binary under test is the signed one: it must carry the entitlement.
    assert_json checks.2.name entitlement || return 1
    assert_json checks.2.status ok || return 1
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
    run_avm exec --box anything --env =value -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "NAME=VALUE or the NAME of a variable" || return 1
    run_avm exec --box anything --env not-a-name -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "got not-a-name" || return 1
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
    run_avm version
    assert_status 0 || return 1
    assert_out_contains "agent-vm $_version (control protocol 1, guest protocol 1)" || return 1
    assert_out_contains "sha256 $_digest" || return 1
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
