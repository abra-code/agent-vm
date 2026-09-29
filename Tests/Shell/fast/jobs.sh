#!/bin/bash
#
# Tests/Shell/fast/jobs.sh - `agent-vm job` from the command line: which commands a job runs,
# the id on stdout, the listing and the log, cancel and forget refusals. The jobs here end in
# a moment without a virtual machine (a restore image listing, a stop of a box that is not
# running); Tests/AgentVMKitTests/JobTests.swift runs long jobs, cancel and a lost runner.

# wait_for_job <id> <state>: waits up to 10 s until `job list --json` shows the job in <state>.
wait_for_job() {
    local _tries=0
    local _state
    while [ "$_tries" -lt 100 ]; do
        _state="$("$AGENT_VM" job list --json | /usr/bin/jq -r --arg id "$1" '.[] | select(.id == $id) | .state')"
        [ "$_state" = "$2" ] && return 0
        /bin/sleep 0.1
        _tries=$((_tries + 1))
    done
    fail "job $1: expected state $2, last seen [$_state]"
}

test_a_job_runs_only_agent_vm_long_commands() {
    run_avm job start -- image list
    assert_status 64 || return 1
    assert_err_contains "a job runs image create, image update-guest, image setup, image fetch-ipsw, box start and box stop; not \`image list\`" || return 1
    assert_err_contains "Usage: agent-vm job start" || return 1

    run_avm job start -- box stop
    assert_status 64 || return 1
    assert_err_contains "the job's command: Missing expected argument '<name>'" || return 1

    run_avm job start
    assert_status 64 || return 1
    assert_err_contains "give the command after --" || return 1

    # Without --, the command is not taken for the job's own arguments.
    run_avm job start box stop b1
    assert_status 64 || return 1

    run_avm job start -- job list
    assert_status 64 || return 1
    assert_err_contains "a job runs" || return 1

    # Nothing was recorded for any of them.
    run_avm job list --json
    assert_status 0 || return 1
    assert_eq "$(printf '%s' "$OUT" | /usr/bin/jq length)" "0" "jobs recorded" || return 1
}

test_a_job_prints_its_id_and_ends_done() {
    run_avm job start -- image fetch-ipsw --list
    assert_status 0 || return 1
    local _id="$OUT"
    # Read through $( ) the id comes alone, with no hint for a person.
    [ "$(printf '%s' "$_id" | /usr/bin/grep -c '^[0-9]\{8\}-[0-9]\{6\}-[0-9a-f]\{6\}$')" = "1" ] || fail "not a job id: [$_id]" || return 1
    wait_for_job "$_id" done || return 1

    run_avm job list --json
    local _entry
    _entry="$(printf '%s' "$OUT" | /usr/bin/jq -c --arg id "$_id" '.[] | select(.id == $id) | [.command, .targets, .status]')"
    assert_eq "$_entry" '[["image","fetch-ipsw","--list","--json"],["ipsw"],0]' "the job's command (with --json), targets and status" || return 1

    run_avm job list
    assert_status 0 || return 1
    assert_out_contains "$_id  done      image fetch-ipsw --list" || return 1

    run_avm job log "$_id"
    assert_status 0 || return 1
    assert_out_contains "Job $_id is done" || return 1

    # The command's result is kept.
    assert_eq "$(/bin/cat "$AGENT_VM_HOME/Jobs/$_id/out" | /usr/bin/jq -c .)" "[]" "the command's stdout" || return 1
}

test_a_failed_job_keeps_agent_vms_message() {
    fake_image dev
    run_avm box create b1 --image dev
    assert_status 0 || return 1
    run_avm job start --json -- box stop b1
    assert_status 0 || return 1
    local _id
    _id="$(json_value id)"
    assert_json targets.0 box:b1 || return 1
    wait_for_job "$_id" failed || return 1

    run_avm job list --json
    local _entry
    _entry="$(printf '%s' "$OUT" | /usr/bin/jq -r --arg id "$_id" '.[] | select(.id == $id) | "\(.status) \(.error)"')"
    assert_eq "$_entry" "1 box b1 is not running; start it with \`agent-vm box start b1\`" "status and error" || return 1

    run_avm job list
    assert_out_contains "status 1: box b1 is not running" || return 1

    run_avm job log "$_id"
    assert_out_contains "Error: box b1 is not running" || return 1
    assert_out_contains "Job $_id failed (status 1)" || return 1

    run_avm job log "$_id" --json
    assert_status 0 || return 1
    assert_json job.state failed || return 1
    assert_json events 0 || return 1

    run_avm job log "$_id" --follow --json
    assert_status 64 || return 1
}

test_cancel_and_forget_refusals() {
    run_avm job start -- image fetch-ipsw --list
    local _id="$OUT"
    wait_for_job "$_id" done || return 1

    run_avm job cancel "$_id"
    assert_status 1 || return 1
    assert_err_contains "job $_id is not running" || return 1

    run_avm job forget "$_id"
    assert_status 0 || return 1
    assert_out_contains "Forgot job $_id" || return 1
    assert_missing "$AGENT_VM_HOME/Jobs/$_id" || return 1

    run_avm job forget "$_id"
    assert_status 1 || return 1
    assert_err_contains "no job $_id" || return 1

    run_avm job log ../Images
    assert_status 1 || return 1
    assert_err_contains "../Images is not a job id" || return 1
}

test_a_job_after_another() {
    run_avm job start --after ../x -- image fetch-ipsw --list
    assert_status 64 || return 1
    assert_err_contains "../x is not a job id" || return 1

    run_avm job start --after 20260101-000000-abcdef -- image fetch-ipsw --list
    assert_status 1 || return 1
    assert_err_contains "no job 20260101-000000-abcdef" || return 1

    run_avm job start -- box stop nobox
    local _failed="$OUT"
    wait_for_job "$_failed" failed || return 1
    run_avm job start --after "$_failed" -- image fetch-ipsw --list
    assert_status 1 || return 1
    assert_err_contains "job $_failed failed, so a job after it would never run" || return 1

    run_avm job start -- image fetch-ipsw --list
    local _first="$OUT"
    run_avm job start --json --after "$_first" -- image fetch-ipsw --list
    assert_status 0 || return 1
    assert_json after "$_first" || return 1
    local _second
    _second="$(json_value id)"
    wait_for_job "$_second" done || return 1
}
