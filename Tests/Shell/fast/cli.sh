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
