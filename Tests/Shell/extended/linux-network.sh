#!/bin/bash
#
# Tests/Shell/extended/linux-network.sh - the network of a real Linux box: in allowlist mode no
# network card at all and no way out but the proxy, apt and ssh through it, rules changed while
# it runs; in open mode a card and none of the proxy's files. Needs the internet (example.com,
# www.iana.org, deb.debian.org, github.com). From the ready Linux image
# $AGENT_VM_TEST_LINUX_IMAGE; without it every test is skipped.

file_setup() {
    start_linux_file_box "shtest-lnet-$$" --allow example.com
}

file_teardown() {
    stop_file_box
}

# http_code <url> [curl options...]: the HTTP status curl gets from inside the box ("000" when
# the connection itself failed).
http_code() {
    local _url="$1"
    shift
    "$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' "$@" "$_url" 2>/dev/null
}

test_allowlist_allows_and_refuses() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    assert_eq "$(http_code https://example.com)" "200" "allowed host" || return 1
    assert_eq "$(http_code http://example.com)" "200" "allowed host, plain HTTP" || return 1
    assert_eq "$(http_code https://www.iana.org)" "000" "refused host" || return 1
    run_avm box netlog "$BOX" --json
    assert_status 0 || return 1
    assert_contains "$OUT" "example.com" "the log" || return 1
    run_avm box netlog "$BOX" --denied --json
    assert_contains "$OUT" "www.iana.org" "the log of refusals" || return 1
}

# No card: nothing but the loopback, no name is resolved, and nothing connects without the
# proxy, at once (there is no route to wait on).
test_there_is_no_card_and_no_way_around_the_proxy() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- /usr/bin/ls /sys/class/net
    assert_eq "$OUT" "lo" "network devices" || return 1
    local _began
    _began="$(/bin/date +%s)"
    run_avm exec --box "$BOX" -- /usr/bin/getent hosts example.com
    [ "$STATUS" -ne 0 ] || { fail "a name was resolved without a network"; return 1; }
    run_avm exec --box "$BOX" -- /usr/bin/curl -sS -m 5 --noproxy '*' -o /dev/null https://1.1.1.1
    [ "$STATUS" -ne 0 ] || { fail "a direct connection got out"; return 1; }
    run_avm exec --box "$BOX" --user root -- /usr/bin/curl -sS -m 5 --noproxy '*' -o /dev/null https://1.1.1.1
    [ "$STATUS" -ne 0 ] || { fail "root's direct connection got out"; return 1; }
    local _took=$(( $(/bin/date +%s) - _began ))
    [ "$_took" -lt 12 ] || { fail "failing without a network took $_took s"; return 1; }
    # The files that tell apt, ssh and other shells about the proxy are there.
    run_avm exec --box "$BOX" -- /usr/bin/cat /etc/apt/apt.conf.d/90agent-vm-proxy /etc/profile.d/agent-vm-proxy.sh /etc/ssh/ssh_config.d/agent-vm.conf
    assert_status 0 || return 1
    assert_out_contains 'Acquire::https::Proxy "http://127.0.0.1:3128";' || return 1
    assert_out_contains "export HTTPS_PROXY=http://127.0.0.1:3128" || return 1
    assert_out_contains "ProxyCommand /usr/bin/nc -X connect -x 127.0.0.1:3128 %h %p" || return 1
    # Allowed by name, but it resolves to this machine: refused.
    run_avm box network "$BOX" --allow localtest.me
    assert_status 0 || return 1
    local _code
    _code="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://localtest.me 2>&1)"
    assert_contains "$_code" "502" "rebinding defense" || return 1
    run_avm box network "$BOX" --disallow localtest.me
    assert_status 0 || return 1
}

# The guest daemon is the one thing listening on vsock, and no ssh server is anywhere.
test_no_ssh_and_no_other_vsock_listener() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" --user root -- /usr/bin/ss -H -l --vsock
    assert_status 0 || return 1
    assert_eq "$(printf '%s\n' "$OUT" | /usr/bin/grep -c .)" "1" "vsock listeners" || return 1
    assert_out_contains ":1024 " || return 1
    run_avm exec --box "$BOX" --user root -- /usr/bin/ss -H -l -t -n
    assert_status 0 || return 1
    assert_not_contains "$OUT" ":22 " "TCP listeners" || return 1
    assert_out_contains "127.0.0.1:3128" || return 1
    run_avm exec --box "$BOX" -- /usr/bin/test -e /usr/sbin/sshd
    [ "$STATUS" -ne 0 ] || { fail "an ssh server is installed"; return 1; }
    # A connection from the box to the Mac's proxy port reaches the same proxy and the same
    # refusal: the relay is not a secret way, only a convenience.
    run_avm exec --box "$BOX" -- /usr/bin/curl -sS -m 10 -o /dev/null -w '%{http_code}' -x http://127.0.0.1:3128 https://www.iana.org
    [ "$STATUS" -ne 0 ] || { fail "a refused host was reached through the relay"; return 1; }
}

test_apt_through_the_proxy() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    # apt calls a list it could not fetch a warning and ends with 0: its words say what happened.
    run_avm exec --box "$BOX" --user root -- /usr/bin/apt-get -q update
    assert_contains "$OUT$ERR" "403 Forbidden" "apt-get update without the pack" || return 1
    run_avm box netlog "$BOX" --denied --json
    assert_contains "$OUT" "deb.debian.org" "the log of refusals" || return 1
    run_avm box network "$BOX" --allow pack:debian
    assert_status 0 || return 1
    run_avm exec --box "$BOX" --user root -- /usr/bin/apt-get -q update
    assert_status 0 || return 1
    assert_not_contains "$OUT$ERR" "Failed to fetch" "apt-get update with the pack" || return 1
    run_avm exec --box "$BOX" --user root --env DEBIAN_FRONTEND=noninteractive -- /usr/bin/apt-get -q -y install --reinstall hostname
    assert_status 0 || return 1
    run_avm box network "$BOX" --disallow pack:debian
    assert_status 0 || return 1
}

test_ssh_through_the_proxy() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box network "$BOX" --allow pack:github
    assert_status 0 || return 1
    # No key: "Permission denied (publickey)" proves the connection got to GitHub's ssh server.
    run_avm exec --box "$BOX" -- /usr/bin/ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes git@github.com
    assert_err_contains "Permission denied (publickey)" || return 1
    run_avm box network "$BOX" --disallow pack:github
    assert_status 0 || return 1
    run_avm exec --box "$BOX" -- /usr/bin/ssh -T -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 git@github.com
    assert_not_contains "$ERR" "Permission denied (publickey)" "ssh without the pack" || return 1
}

test_rules_change_on_a_running_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    assert_eq "$(http_code https://www.iana.org)" "000" "before the rule" || return 1
    run_avm box network "$BOX" --allow www.iana.org
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "200" "after the rule" || return 1
    run_avm box network "$BOX" --disallow www.iana.org
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "000" "after the rule was removed" || return 1
}

# The Mac is not reachable from a proxied box by any of its addresses: there is no card.
test_the_mac_is_unreachable() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    local _port=$(( 20000 + $$ % 20000 ))
    /usr/bin/nc -l -k "$_port" > /dev/null 2>&1 &
    local _listener=$!
    local _addresses="192.168.64.1"
    local _interface
    _interface="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')"
    if [ -n "$_interface" ]; then
        local _lan
        _lan="$(/usr/sbin/ipconfig getifaddr "$_interface" 2>/dev/null)"
        [ -n "$_lan" ] && _addresses="$_addresses $_lan"
    fi
    /bin/sleep 1
    local _address
    local _failed=0
    for _address in $_addresses; do
        run_avm exec --box "$BOX" -- /usr/bin/nc -z -w 3 "$_address" "$_port"
        [ "$STATUS" -ne 0 ] || _failed=1
    done
    kill "$_listener"
    wait "$_listener" 2>/dev/null
    [ "$_failed" -eq 0 ] || { fail "the box reached a listener on the Mac"; return 1; }
}

# The same disk in open mode: a card with an address, no proxy variables, the three files gone;
# and back in allowlist mode they are there again.
test_open_mode_has_a_card_and_no_proxy_files() {
    require_linux_image || return $(( $? == 1 ? 0 : 1 ))
    local _box="shtest-lopen-$$"
    cleanup_on_exit box "$_box"
    run_avm box create "$_box" --image "$LINUX_TEST_IMAGE" --net open
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'ls /sys/class/net | grep -c "^en"; printenv HTTPS_PROXY; ls /etc/apt/apt.conf.d/90agent-vm-proxy /etc/profile.d/agent-vm-proxy.sh /etc/ssh/ssh_config.d/agent-vm.conf 2>/dev/null | wc -l'
    assert_eq "$OUT" $'1\n0' "a card, no proxy variable, no proxy files" || return 1
    run_avm exec --box "$_box" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://example.com
    assert_eq "$OUT" "200" "the open network" || return 1
    assert_contains "$(/bin/cat "$(box_folder "$_box")/supervisor.log")" "Network: open (NAT)" "the supervisor's log" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
    run_avm box network "$_box" --net allowlist
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'ls /sys/class/net; ls /etc/apt/apt.conf.d/90agent-vm-proxy /etc/profile.d/agent-vm-proxy.sh /etc/ssh/ssh_config.d/agent-vm.conf | wc -l'
    assert_eq "$OUT" $'lo\n3' "no card, the three files" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
    # And open once more: the files that were written are removed.
    run_avm box network "$_box" --net open
    assert_status 0 || return 1
    run_avm box start "$_box"
    assert_status 0 || return 1
    run_avm exec --box "$_box" -- /bin/sh -c 'ls /etc/apt/apt.conf.d/90agent-vm-proxy /etc/profile.d/agent-vm-proxy.sh /etc/ssh/ssh_config.d/agent-vm.conf 2>/dev/null | wc -l'
    assert_eq "$OUT" "0" "the three files in open mode again" || return 1
    run_avm box stop "$_box"
    assert_status 0 || return 1
}
