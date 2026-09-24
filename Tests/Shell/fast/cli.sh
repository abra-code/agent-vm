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
    run_avm exec --box anything --env NOVALUE -- /usr/bin/true
    assert_status 64 || return 1
    assert_err_contains "NAME=VALUE" || return 1
}
